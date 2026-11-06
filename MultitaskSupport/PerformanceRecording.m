#import "PerformanceRecording.h"
#import "PerformanceMetrics.h"

@interface LCPerformanceRecording ()
@property(nonatomic) NSDictionary *context;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *baselines;
@property(nonatomic) NSMutableArray<NSDictionary *> *samples;
@property(nonatomic) NSUInteger segment, nextSample, cpuSamples;
@property(nonatomic) NSTimeInterval startedAt, segmentStartedAt, measuredSeconds;
@property(nonatomic) double weightedCPU, peakCPU, peakFootprint;
@end

@implementation LCPerformanceRecording
- (instancetype)init {
    if ((self = [super init])) {
        _baselines = [NSMutableDictionary dictionary];
        _samples = [NSMutableArray array];
        [self resetAtTime:NSProcessInfo.processInfo.systemUptime];
    }
    return self;
}
- (void)resetAtTime:(NSTimeInterval)time {
    self.startedAt = time;
    self.segment = self.nextSample = 0;
    self.context = nil;
    [self.baselines removeAllObjects];
    [self.samples removeAllObjects];
    _snapshot = @{};
}
- (void)suspend {
    // Keep the last results available to export, but never span a suspension.
    self.context = nil;
    [self.baselines removeAllObjects];
}
- (BOOL)prepareForProcesses:(NSDictionary<NSString *, NSDictionary *> *)processes
                      sync:(NSDictionary *)sync atTime:(NSTimeInterval)time {
    NSDictionary *context = @{@"processes": processes.copy, @"epoch": sync[@"epoch"] ?: @0};
    if ([self.context isEqual:context]) return NO;
    self.context = context;
    self.segment++;
    self.segmentStartedAt = time;
    self.measuredSeconds = self.weightedCPU = self.peakCPU = self.peakFootprint = 0;
    self.cpuSamples = 0;
    [self.baselines removeAllObjects];
    _snapshot = @{@"segment": @(self.segment), @"elapsed": @(time - self.startedAt), @"segmentElapsed": @0,
        @"processes": @[], @"processCount": @(processes.count), @"cpuCoverage": @0, @"memoryCoverage": @0,
        @"cpuSamples": @0, @"measuredSeconds": @0, @"sync": sync.copy};
    return YES;
}
static NSNumber *LCFiniteMetric(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= 0 ? value : nil;
}
- (void)recordSamples:(NSDictionary<NSString *, NSDictionary *> *)samples
                sync:(NSDictionary *)sync atTime:(NSTimeInterval)time
        thermalState:(NSInteger)thermalState lowPowerMode:(BOOL)lowPowerMode now:(NSTimeInterval)now {
    if (!self.context || ![self.context[@"epoch"] isEqual:sync[@"epoch"] ?: @0] || time < self.segmentStartedAt) return;
    NSDictionary<NSString *, NSDictionary *> *expected = self.context[@"processes"];
    NSMutableArray *processes = [NSMutableArray array];
    double totalCPU = 0, totalMemory = 0, hostInterval = 0;
    NSUInteger cpuCount = 0, memoryCount = 0;
    NSArray<NSString *> *keys = [expected.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [expected[left][@"number"] compare:expected[right][@"number"]];
    }];
    for (NSString *key in keys) {
        NSDictionary *identity = expected[key], *raw = samples[key], *baseline = self.baselines[key];
        NSNumber *timestamp = LCFiniteMetric(raw[@"timestamp"]);
        BOOL fresh = timestamp && timestamp.doubleValue >= self.segmentStartedAt && timestamp.doubleValue > 0 &&
            now >= timestamp.doubleValue && now - timestamp.doubleValue <= 2.5;
        NSNumber *cpu = fresh ? LCFiniteMetric(raw[@"cpuSeconds"]) : nil;
        NSNumber *memory = fresh ? LCFiniteMetric(raw[@"footprintBytes"]) : nil;
        NSMutableDictionary *process = [@{@"number": identity[@"number"], @"window": identity[@"window"], @"role": identity[@"role"]} mutableCopy];
        if (fresh) process[@"sampleElapsed"] = @(timestamp.doubleValue - self.startedAt);
        if (cpu && identity[@"instance"] == baseline[@"instance"] && [identity[@"pid"] isEqual:baseline[@"pid"]]) {
            double percent = LCPerformanceCPUPercent([baseline[@"cpu"] doubleValue], [baseline[@"time"] doubleValue], cpu.doubleValue, timestamp.doubleValue);
            if (isfinite(percent)) {
                double interval = timestamp.doubleValue - [baseline[@"time"] doubleValue];
                process[@"cpu"] = @(percent);
                process[@"cpuInterval"] = @(interval);
                totalCPU += percent;
                cpuCount++;
                if ([key isEqualToString:@"host"]) hostInterval = interval;
            }
        }
        if (cpu) self.baselines[key] = @{@"cpu": cpu, @"time": timestamp, @"pid": identity[@"pid"], @"instance": identity[@"instance"]};
        else [self.baselines removeObjectForKey:key];
        if (memory) {
            double mib = memory.doubleValue / (1024.0 * 1024.0);
            process[@"memoryMiB"] = @(mib);
            totalMemory += mib;
            memoryCount++;
        }
        [processes addObject:process.copy];
    }
    NSMutableDictionary *snapshot = [@{@"sample": @(++self.nextSample), @"segment": @(self.segment),
        @"elapsed": @(time - self.startedAt), @"segmentElapsed": @(time - self.segmentStartedAt),
        @"processes": processes.copy, @"processCount": @(processes.count), @"cpuCoverage": @(cpuCount), @"memoryCoverage": @(memoryCount),
        @"thermalState": @(thermalState), @"lowPowerMode": @(lowPowerMode), @"sync": sync.copy} mutableCopy];
    if (cpuCount == processes.count && cpuCount) {
        snapshot[@"totalCPU"] = @(totalCPU);
        if (hostInterval > 0 && hostInterval <= 3.0) {
            snapshot[@"cpuInterval"] = @(hostInterval);
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
    [self.samples addObject:_snapshot];
    // Retain whole sampling rounds so each combined row keeps all its process rows.
    if (self.samples.count > 300) [self.samples removeObjectAtIndex:0];
}
- (NSUInteger)sampleCount { return self.samples.count; }

static NSString *LCCSVField(id value) {
    if ([value isKindOfClass:NSNumber.class]) return LCFiniteMetric(value) ? [value descriptionWithLocale:@{NSLocaleDecimalSeparator: @"."}] : @"";
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *field = value;
    // Metadata is normally a version string. Keep unusual builds inert in spreadsheets.
    if (field.length && [@"=+-@\t\r" rangeOfString:[field substringToIndex:1]].location != NSNotFound) field = [@"'" stringByAppendingString:field];
    if ([field rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@",\"\r\n"]].location != NSNotFound) {
        field = [NSString stringWithFormat:@"\"%@\"", [field stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
    }
    return field;
}
static void LCAppendCSVRow(NSMutableString *report, NSArray<NSString *> *columns, NSDictionary *row) {
    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:columns.count];
    for (NSString *column in columns) [fields addObject:LCCSVField(row[column])];
    [report appendFormat:@"%@\r\n", [fields componentsJoinedByString:@","]];
}
- (NSString *)csvReportWithMetadata:(NSDictionary<NSString *, id> *)metadata {
    NSArray<NSString *> *columns = @[@"schema_version", @"build", @"ios_version", @"logical_cpus", @"sample", @"segment", @"elapsed_s", @"segment_elapsed_s",
        @"record_type", @"process_number", @"window_number", @"role", @"processes", @"cpu_coverage", @"memory_coverage",
        @"cpu_pct", @"footprint_mib", @"cpu_interval_s", @"sample_elapsed_s", @"thermal_state", @"low_power_mode", @"sync_mode", @"sync_active", @"followers",
        @"response_p50_ms", @"response_p95_ms", @"response_samples", @"delivered_commands", @"pending_commands", @"in_flight", @"peak_pending", @"host_coalesced_moves", @"sync_status"];
    NSMutableString *report = [NSMutableString stringWithFormat:@"%@\r\n", [columns componentsJoinedByString:@","]];
    for (NSDictionary *s in self.samples) {
        NSDictionary *sync = s[@"sync"];
        NSMutableDictionary *common = [@{@"schema_version": @3, @"build": metadata[@"build"] ?: @"unknown", @"ios_version": metadata[@"ios"] ?: @"unknown",
            @"logical_cpus": metadata[@"cpus"] ?: @"", @"sample": s[@"sample"], @"segment": s[@"segment"],
            @"elapsed_s": s[@"elapsed"], @"segment_elapsed_s": s[@"segmentElapsed"], @"processes": s[@"processCount"],
            @"cpu_coverage": s[@"cpuCoverage"], @"memory_coverage": s[@"memoryCoverage"], @"thermal_state": s[@"thermalState"],
            @"low_power_mode": s[@"lowPowerMode"], @"sync_mode": sync[@"mode"] ?: @"", @"sync_active": sync[@"active"] ?: @"", @"followers": sync[@"targets"] ?: @"",
            @"sync_status": sync[@"statusKey"] ?: @""} mutableCopy];
        NSMutableDictionary *combined = common.mutableCopy;
        [combined addEntriesFromDictionary:@{@"record_type": @"combined", @"role": @"combined", @"cpu_pct": s[@"totalCPU"] ?: @"",
            @"footprint_mib": s[@"totalMemoryMiB"] ?: @"", @"cpu_interval_s": s[@"cpuInterval"] ?: @"", @"sample_elapsed_s": s[@"elapsed"],
            @"response_p50_ms": sync[@"responseP50Ms"] ?: @"", @"response_p95_ms": sync[@"responseP95Ms"] ?: @"",
            @"response_samples": sync[@"responseSamples"] ?: @0, @"delivered_commands": sync[@"packets"] ?: @0,
            @"pending_commands": sync[@"pending"] ?: @0, @"in_flight": sync[@"inFlight"] ?: @0,
            @"peak_pending": sync[@"queuePeak"] ?: @0, @"host_coalesced_moves": sync[@"coalesced"] ?: @0}];
        LCAppendCSVRow(report, columns, combined);
        for (NSDictionary *process in s[@"processes"]) {
            NSMutableDictionary *row = common.mutableCopy;
            [row addEntriesFromDictionary:@{@"record_type": @"process", @"process_number": process[@"number"], @"window_number": process[@"window"], @"role": process[@"role"],
                @"cpu_pct": process[@"cpu"] ?: @"", @"footprint_mib": process[@"memoryMiB"] ?: @"",
                @"cpu_interval_s": process[@"cpuInterval"] ?: @"", @"sample_elapsed_s": process[@"sampleElapsed"] ?: @""}];
            LCAppendCSVRow(report, columns, row);
        }
    }
    return report.copy;
}
@end
