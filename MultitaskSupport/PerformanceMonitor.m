#import "PerformanceMonitor.h"
#import "PerformanceRecording.h"
#import "ProcessMetrics.h"
#import "TapSyncCoordinator.h"

NSNotificationName const LCPerformanceDidChangeNotification = @"LCPerformanceDidChange";

@interface LCPerformanceMonitor ()
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) BOOL applicationActive;
@property(nonatomic) LCPerformanceRecording *recording;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *round;
@property(nonatomic) NSDictionary *roundSync;
@property(nonatomic) NSTimeInterval roundTime;
@property(nonatomic) NSInteger roundThermalState;
@property(nonatomic) BOOL roundLowPowerMode;
@property(nonatomic) NSMapTable<LCTapSyncPeer *, NSDictionary *> *processNumbers;
@property(nonatomic) NSDictionary *scope;
@property(nonatomic) NSUInteger nextProcessNumber;
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
        _recording = [LCPerformanceRecording new];
        _processNumbers = [NSMapTable weakToStrongObjectsMapTable];
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
- (NSDictionary<NSString *, id> *)snapshot { return self.recording.snapshot; }
- (NSUInteger)reportSampleCount { return self.recording.sampleCount; }
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
    LCTapSyncCoordinator.shared.collectsPerformanceData = YES;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // One sample per second in the foreground, with slack for coalesced wakeups.
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 150 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf tick]; });
    dispatch_resume(self.timer);
    [self tick];
}
- (void)stopSampling {
    if (!self.sampling && !self.timer) return;
    if (self.timer) dispatch_source_cancel(self.timer);
    self.timer = nil;
    _sampling = NO;
    self.round = nil;
    self.roundSync = nil;
    self.scope = nil;
    [self.recording suspend];
    LCTapSyncCoordinator.shared.collectsPerformanceData = NO;
    [self changed];
}
- (void)resetMeasurements {
    [self.recording resetAtTime:NSProcessInfo.processInfo.systemUptime];
    self.round = nil;
    self.roundSync = nil;
    self.scope = nil;
    [self.processNumbers removeAllObjects];
    self.nextProcessNumber = 0;
    [LCTapSyncCoordinator.shared resetPerformanceData];
    if (self.sampling) [self tick];
    else [self changed];
}
- (void)tick {
    if (!self.sampling) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
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
        LCTapSyncPeer *peer = peers[container];
        NSNumber *pid = @(peer.expectedProcessIdentifier);
        NSDictionary *identity = [self.processNumbers objectForKey:peer];
        // A relaunched guest gets a new anonymous number even if its PID is reused.
        if (![identity[@"pid"] isEqual:pid]) {
            identity = @{@"number": @(++self.nextProcessNumber), @"pid": pid};
            [self.processNumbers setObject:identity forKey:peer];
        }
        NSString *role = [container isEqualToString:sync.sourceContainer] ? @"source" : [sync.targetContainers containsObject:container] ? @"follower" : @"other";
        expected[key] = @{@"pid": pid, @"number": identity[@"number"], @"window": @([sync windowNumberForContainer:container]), @"role": role, @"instance": peer};
    }
    if (self.scope && ![self.scope isEqual:expected]) [sync resetPerformanceData];
    self.scope = expected.copy;
    NSDictionary *syncSnapshot = sync.performanceSnapshot;
    BOOL newSegment = [self.recording prepareForProcesses:expected sync:syncSnapshot atTime:now];
    // A round straddling a context change cannot be attributed to either condition.
    if (self.round && !newSegment) {
        [self.recording recordSamples:self.round sync:self.roundSync atTime:self.roundTime
            thermalState:self.roundThermalState lowPowerMode:self.roundLowPowerMode now:now];
    }
    NSDictionary *hostSample = LCReadProcessMetrics();
    NSMutableDictionary *round = [NSMutableDictionary dictionaryWithObject:hostSample forKey:@"host"];
    self.round = round;
    self.roundTime = [hostSample[@"timestamp"] doubleValue];
    self.roundSync = syncSnapshot;
    self.roundThermalState = NSProcessInfo.processInfo.thermalState;
    self.roundLowPowerMode = NSProcessInfo.processInfo.lowPowerModeEnabled;
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
    [self changed];
}
- (NSString *)csvReport {
    return [self.recording csvReportWithMetadata:@{@"build": NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"] ?: @"unknown",
        @"ios": UIDevice.currentDevice.systemVersion, @"cpus": @(NSProcessInfo.processInfo.activeProcessorCount)}];
}
@end
