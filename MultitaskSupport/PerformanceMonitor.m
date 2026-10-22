#import "PerformanceMonitor.h"
#import "PerformanceMetrics.h"
#import "ProcessMetrics.h"
#import "TapSyncCoordinator.h"

NSNotificationName const LCPerformanceDidChangeNotification = @"LCPerformanceDidChange";

@interface LCPerformanceMonitor ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) BOOL applicationActive;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *baselines;
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *expected;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *round;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *processNumbers;
@property(nonatomic) NSUInteger nextProcessNumber, cpuSamples;
@property(nonatomic) NSTimeInterval startedAt, measuredSeconds;
@property(nonatomic) double weightedCPU, peakCPU, peakFootprint;
@property(nonatomic) NSMutableArray<NSString *> *reportRows;
@end

@implementation LCPerformanceMonitor
+ (instancetype)shared {
    static LCPerformanceMonitor *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _applicationActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        _snapshot = @{};
        _baselines = [NSMutableDictionary dictionary];
        _processNumbers = [NSMutableDictionary dictionary];
        _reportRows = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBecameActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:)
            name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneBecameActive:)
            name:UISceneDidActivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneWillDeactivate:)
            name:UISceneWillDeactivateNotification object:nil];
    }
    return self;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:LCPerformanceDidChangeNotification object:self]; }
- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) [self resetMeasurements];
    [self updateVisibility];
    [self changed];
}
- (void)applicationBecameActive:(NSNotification *)note { self.applicationActive = YES; [self updateVisibility]; }
- (void)applicationWillResignActive:(NSNotification *)note { self.applicationActive = NO; [self stopSampling]; }
- (void)sceneBecameActive:(NSNotification *)note { [self updateVisibility]; }
- (void)sceneWillDeactivate:(NSNotification *)note {
    if (note.object == self.hostView.window.windowScene) [self stopSampling];
}
- (void)updateVisibility {
    UIWindow *window = self.hostView.window;
    BOOL shouldSample = self.enabled && self.applicationActive && window && !window.hidden && !self.hostView.hidden &&
        window.windowScene.activationState == UISceneActivationStateForegroundActive;
    if (!shouldSample) { [self stopSampling]; return; }
    if (self.timer) return;
    _sampling = YES;
    [self.baselines removeAllObjects];
    self.round = nil;
    NSMutableDictionary *waiting = self.snapshot.mutableCopy;
    [waiting removeObjectsForKeys:@[@"totalCPU", @"totalMemoryMiB", @"processes"]];
    waiting[@"cpuCoverage"] = @0;
    waiting[@"memoryCoverage"] = @0;
    waiting[@"sync"] = LCTapSyncCoordinator.shared.performanceSnapshot;
    _snapshot = waiting.copy;
    LCTapSyncCoordinator.shared.collectsPerformanceData = YES;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // One sample per second in the foreground, with slack for coalesced wakeups.
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 150 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf tick]; });
    dispatch_resume(self.timer);
    [self tick];
    [self changed];
}
- (void)stopSampling {
    if (!self.sampling && !self.timer) return;
    if (self.timer) dispatch_source_cancel(self.timer);
    self.timer = nil;
    _sampling = NO;
    self.round = nil;
    self.expected = nil;
    [self.baselines removeAllObjects];
    LCTapSyncCoordinator.shared.collectsPerformanceData = NO;
    [self changed];
}
- (void)resetMeasurements {
    self.startedAt = NSProcessInfo.processInfo.systemUptime;
    self.measuredSeconds = self.weightedCPU = self.peakCPU = self.peakFootprint = 0;
    self.cpuSamples = 0;
    self.round = nil;
    self.expected = nil;
    [self.baselines removeAllObjects];
    [self.processNumbers removeAllObjects];
    self.nextProcessNumber = 0;
    [self.reportRows removeAllObjects];
    _snapshot = @{};
    [LCTapSyncCoordinator.shared resetPerformanceData];
    if (self.sampling) [self tick];
    [self changed];
}
- (void)tick {
    if (!self.sampling) return;
    if (self.round) [self publishRound];
    LCTapSyncCoordinator *sync = LCTapSyncCoordinator.shared;
    NSDictionary<NSString *, LCTapSyncPeer *> *peers = sync.performancePeers;
    NSMutableDictionary *expected = [NSMutableDictionary dictionary];
    expected[@"host"] = @{@"pid": @(NSProcessInfo.processInfo.processIdentifier), @"number": @0, @"window": @0, @"role": @"host", @"instance": NSNull.null};
    NSArray<NSString *> *containers = [peers.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSUInteger a = [sync windowNumberForContainer:left], b = [sync windowNumberForContainer:right];
        if (a != b) return a < b ? NSOrderedAscending : NSOrderedDescending;
        return [left compare:right];
    }];
    for (NSString *container in containers) {
        NSString *key = [@"guest:" stringByAppendingString:container];
        if (!self.processNumbers[key]) self.processNumbers[key] = @(++self.nextProcessNumber);
        NSString *role = [container isEqualToString:sync.sourceContainer] ? @"source" : [sync.targetContainers containsObject:container] ? @"follower" : @"other";
        expected[key] = @{@"pid": @(peers[container].expectedProcessIdentifier), @"number": self.processNumbers[key],
            @"window": @([sync windowNumberForContainer:container]), @"role": role, @"instance": peers[container]};
    }
    for (NSString *key in self.baselines.allKeys) if (!expected[key]) [self.baselines removeObjectForKey:key];
    self.expected = expected;
    NSMutableDictionary *round = [NSMutableDictionary dictionaryWithObject:LCReadProcessMetrics() forKey:@"host"];
    self.round = round;
    __weak typeof(self) weakSelf = self;
    for (NSString *container in containers) {
        NSString *key = [@"guest:" stringByAppendingString:container];
        [peers[container] samplePerformanceWithReply:^(NSDictionary *sample) {
            LCPerformanceMonitor *monitor = weakSelf;
            // Disabling/resetting/suspending discards late replies. A slow process
            // shows as unavailable; it never stalls the other processes or input.
            if (monitor.sampling && monitor.round == round && sample) round[key] = sample;
        }];
    }
}
static NSNumber *LCFiniteMetric(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= 0 ? value : nil;
}
- (void)publishRound {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSMutableArray *processes = [NSMutableArray array];
    double totalCPU = 0, totalMemory = 0;
    double hostInterval = 0;
    NSUInteger cpuCount = 0, memoryCount = 0;
    NSArray<NSString *> *keys = [self.expected.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [self.expected[left][@"number"] compare:self.expected[right][@"number"]];
    }];
    for (NSString *key in keys) {
        NSDictionary *identity = self.expected[key];
        NSDictionary *raw = self.round[key];
        NSNumber *time = LCFiniteMetric(raw[@"timestamp"]);
        BOOL fresh = time && time.doubleValue > 0 && now >= time.doubleValue && now - time.doubleValue <= 2.5;
        NSNumber *cpu = fresh ? LCFiniteMetric(raw[@"cpuSeconds"]) : nil;
        NSNumber *memory = fresh ? LCFiniteMetric(raw[@"footprintBytes"]) : nil;
        NSDictionary *baseline = self.baselines[key];
        if ([key isEqualToString:@"host"] && cpu && baseline[@"time"]) hostInterval = time.doubleValue - [baseline[@"time"] doubleValue];
        NSMutableDictionary *process = [@{@"number": identity[@"number"], @"window": identity[@"window"], @"role": identity[@"role"]} mutableCopy];
        if (cpu && identity[@"instance"] == baseline[@"instance"] && [identity[@"pid"] isEqual:baseline[@"pid"]]) {
            double percent = LCPerformanceCPUPercent([baseline[@"cpu"] doubleValue], [baseline[@"time"] doubleValue], cpu.doubleValue, time.doubleValue);
            if (isfinite(percent)) { process[@"cpu"] = @(percent); totalCPU += percent; cpuCount++; }
        }
        if (cpu) self.baselines[key] = @{@"cpu": cpu, @"time": time, @"pid": identity[@"pid"], @"instance": identity[@"instance"]};
        else [self.baselines removeObjectForKey:key];
        if (memory) {
            double mib = memory.doubleValue / (1024.0 * 1024.0);
            process[@"memoryMiB"] = @(mib);
            totalMemory += mib;
            memoryCount++;
        }
        [processes addObject:process.copy];
    }
    NSDictionary *sync = LCTapSyncCoordinator.shared.performanceSnapshot;
    NSMutableDictionary *snapshot = [@{@"processes": processes.copy, @"processCount": @(processes.count),
        @"cpuCoverage": @(cpuCount), @"memoryCoverage": @(memoryCount), @"elapsed": @(now - self.startedAt),
        @"thermalState": @(NSProcessInfo.processInfo.thermalState), @"lowPowerMode": @(NSProcessInfo.processInfo.lowPowerModeEnabled),
        @"sync": sync} mutableCopy];
    if (cpuCount == processes.count && cpuCount) {
        snapshot[@"totalCPU"] = @(totalCPU);
        if (hostInterval > 0 && hostInterval <= 3.0) {
            self.weightedCPU += totalCPU * hostInterval;
            self.measuredSeconds += hostInterval;
            self.cpuSamples++;
        }
        self.peakCPU = MAX(self.peakCPU, totalCPU);
    }
    if (memoryCount == processes.count && memoryCount) {
        snapshot[@"totalMemoryMiB"] = @(totalMemory);
        self.peakFootprint = MAX(self.peakFootprint, totalMemory);
    }
    if (self.measuredSeconds > 0) snapshot[@"averageCPU"] = @(self.weightedCPU / self.measuredSeconds);
    if (self.cpuSamples) snapshot[@"peakCPU"] = @(self.peakCPU);
    if (self.peakFootprint > 0) snapshot[@"peakMemoryMiB"] = @(self.peakFootprint);
    snapshot[@"cpuSamples"] = @(self.cpuSamples);
    snapshot[@"measuredSeconds"] = @(self.measuredSeconds);
    _snapshot = snapshot.copy;
    [self appendReportRow];
    [self changed];
}
- (void)appendReportRow {
    NSDictionary *s = self.snapshot, *sync = s[@"sync"];
    NSDictionary *host = [s[@"processes"] firstObject];
    NSArray *values = @[s[@"elapsed"], s[@"processCount"], s[@"cpuCoverage"], s[@"memoryCoverage"],
        s[@"totalCPU"] ?: @"", host[@"cpu"] ?: @"", s[@"totalMemoryMiB"] ?: @"", host[@"memoryMiB"] ?: @"",
        s[@"thermalState"], s[@"lowPowerMode"], sync[@"mode"], sync[@"active"], sync[@"targets"],
        sync[@"responseP50Ms"] ?: @"", sync[@"responseP95Ms"] ?: @"", sync[@"responseSamples"],
        sync[@"packets"], sync[@"pending"], sync[@"inFlight"], sync[@"queuePeak"], sync[@"coalesced"]];
    NSMutableArray *fields = [NSMutableArray array];
    for (id value in values) {
        [fields addObject:[value isKindOfClass:NSNumber.class] ? [value descriptionWithLocale:@{NSLocaleDecimalSeparator: @"."}] : value];
    }
    [self.reportRows addObject:[fields componentsJoinedByString:@","]];
    // Diagnostics stay in memory, bounded to the latest five minutes. Export is explicit.
    if (self.reportRows.count > 300) [self.reportRows removeObjectAtIndex:0];
}
- (NSString *)csvReport {
    NSMutableString *report = [NSMutableString stringWithString:@"# LiveContainer performance samples; latest 300 foreground samples since reset\n"];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"] ?: @"unknown";
    [report appendFormat:@"# Build: %@; iOS: %@; logical CPUs: %lu\n", version, UIDevice.currentDevice.systemVersion, (unsigned long)NSProcessInfo.processInfo.activeProcessorCount];
    [report appendString:@"# CPU: 100% = one core. Memory: process physical footprint, MiB. Scope: host + running guest processes; excludes system compositor/GPU and other apps.\n"];
    [report appendString:@"# Blank = missing/warming/stale, never zero. Totals require every process. Response = host send to all followers' input replies, includes scheduling/replay holds; not screen latency.\n"];
    [report appendString:@"# Response p50/p95: nearest rank, last 10 s, at most 600 successful group commands. Thermal: 0 nominal, 1 fair, 2 serious, 3 critical. Mode: 0 taps, 1 single finger, 2 two fingers.\n"];
    [report appendString:@"elapsed_s,processes,cpu_coverage,memory_coverage,total_cpu_pct,host_cpu_pct,total_footprint_mib,host_footprint_mib,thermal_state,low_power_mode,sync_mode,sync_active,followers,response_p50_ms,response_p95_ms,response_samples,delivered_commands,pending_commands,in_flight,peak_pending,host_coalesced_moves\n"];
    [report appendString:[self.reportRows componentsJoinedByString:@"\n"]];
    [report appendString:@"\n"];
    return report.copy;
}
@end
