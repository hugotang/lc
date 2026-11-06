#import "../MultitaskSupport/PerformanceRecording.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static NSDictionary *Identity(int pid, NSUInteger number, NSUInteger window, NSString *role, id instance) {
    return @{@"pid": @(pid), @"number": @(number), @"window": @(window), @"role": role,
        @"instance": instance, @"appName": @"PRIVATE-app-name"};
}
static NSDictionary *Raw(double time, double cpu, double memoryMiB) {
    return @{@"timestamp": @(time), @"cpuSeconds": @(cpu), @"footprintBytes": @(memoryMiB * 1024 * 1024),
        @"inputCoordinates": @"PRIVATE-input"};
}
static NSDictionary *Sync(NSUInteger epoch, NSUInteger mode, BOOL active) {
    return @{@"epoch": @(epoch), @"mode": @(mode), @"active": @(active), @"targets": @1,
        @"responseSamples": @0, @"packets": @0, @"coalesced": @0, @"queuePeak": @0, @"pending": @0, @"inFlight": @0,
        @"source": @"PRIVATE-source-id", @"statusKey": active ? @"lc.tapSync.active" : @"lc.tapSync.expiredInput"};
}
static void Record(LCPerformanceRecording *recording, NSDictionary *sync, double time, double hostCPU, double guestCPU) {
    NSMutableDictionary *samples = [@{@"host": Raw(time, hostCPU, 64)} mutableCopy];
    if (isfinite(guestCPU)) samples[@"guest:PRIVATE-container"] = Raw(time, guestCPU, 128);
    [recording recordSamples:samples sync:sync atTime:time thermalState:1 lowPowerMode:NO now:time + 1];
}
static void Metric(NSDictionary *snapshot, NSString *key, double expected) {
    assert(snapshot[key] != nil);
    assert(fabs([snapshot[key] doubleValue] - expected) < 0.00001);
}
static void Write(NSString *report, NSString *path) {
    NSError *error = nil;
    assert([report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]);
    assert(error == nil);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LCPerformanceRecording *recording = [LCPerformanceRecording new];
        [recording resetAtTime:100];
        NSObject *firstInstance = [NSObject new];
        NSDictionary *host = Identity(12345, 0, 0, @"host", NSNull.null);
        NSDictionary *guest = Identity(54321, 1, 1, @"source", firstInstance);
        // Deliberately put the guest first: row order must still be host, then process number.
        NSDictionary *processes = @{@"guest:PRIVATE-container": guest, @"host": host};
        NSDictionary *off = Sync(1, 0, NO);
        LCPerformanceRecording *transitions = [LCPerformanceRecording new];
        [transitions resetAtTime:10];
        assert([transitions prepareForProcesses:processes sync:off atTime:10]);
        Record(transitions, off, 10, 1, 2);
        Record(transitions, off, 11, 1.25, 2.5);
        // Switching away and back still changes the epoch, even when the final mode/state matches.
        NSDictionary *returned = Sync(3, 0, NO);
        assert([transitions prepareForProcesses:processes sync:returned atTime:12]);
        assert(transitions.snapshot[@"averageCPU"] == nil);
        NSUInteger transitionSamples = transitions.sampleCount;
        Record(transitions, off, 11, 1.25, 2.5);
        assert(transitions.sampleCount == transitionSamples);
        NSMutableDictionary *samePIDAndNumber = guest.mutableCopy;
        samePIDAndNumber[@"instance"] = [NSObject new];
        NSDictionary *sameLabels = @{@"host": host, @"guest:PRIVATE-container": samePIDAndNumber.copy};
        assert([transitions prepareForProcesses:sameLabels sync:returned atTime:13]);
        Metric(transitions.snapshot, @"segment", 3);

        assert([recording prepareForProcesses:processes sync:off atTime:100]);
        Record(recording, off, 100, 1, 2);
        assert(recording.snapshot[@"totalCPU"] == nil);
        Metric(recording.snapshot, @"totalMemoryMiB", 192);
        Metric(recording.snapshot, @"cpuCoverage", 0);
        Metric(recording.snapshot, @"segment", 1);
        NSArray *readings = recording.snapshot[@"processes"];
        Metric(readings[0], @"number", 0);
        Metric(readings[1], @"number", 1);
        assert(![recording prepareForProcesses:processes.copy sync:off.copy atTime:101]);

        Record(recording, off, 101, 1.25, 2.5);
        Metric(recording.snapshot, @"totalCPU", 75);
        Metric(recording.snapshot, @"averageCPU", 75);
        Metric(recording.snapshot, @"measuredSeconds", 1);
        Record(recording, off, 103, 2.25, 3.5);
        Metric(recording.snapshot, @"totalCPU", 100);
        Metric(recording.snapshot, @"averageCPU", 275.0 / 3.0);
        Metric(recording.snapshot, @"peakCPU", 100);
        Metric(recording.snapshot, @"measuredSeconds", 3);

        // An unavailable guest remains a row with empty values. Partial CPU is never a total.
        Record(recording, off, 104, 2.5, NAN);
        assert(recording.snapshot[@"totalCPU"] == nil && recording.snapshot[@"totalMemoryMiB"] == nil);
        Metric(recording.snapshot, @"cpuCoverage", 1);
        Metric(recording.snapshot, @"averageCPU", 275.0 / 3.0);
        readings = recording.snapshot[@"processes"];
        assert([readings count] == 2 && readings[1][@"cpu"] == nil && readings[1][@"memoryMiB"] == nil);
        Record(recording, off, 105, 3, 4);
        assert(recording.snapshot[@"totalCPU"] == nil); // Guest must warm up again.
        Record(recording, off, 106, 3.25, 4.5);
        Metric(recording.snapshot, @"totalCPU", 75);
        Metric(recording.snapshot, @"averageCPU", 87.5);
        Metric(recording.snapshot, @"measuredSeconds", 4);

        NSDictionary *stale = @{@"host": Raw(107, 3.5, 64), @"guest:PRIVATE-container": Raw(103, 3.5, 128)};
        [recording recordSamples:stale sync:off atTime:107 thermalState:2 lowPowerMode:YES now:108];
        Metric(recording.snapshot, @"memoryCoverage", 1);
        Metric(recording.snapshot, @"thermalState", 2);
        Metric(recording.snapshot, @"lowPowerMode", 1);
        Record(recording, off, 108, 3.75, 0.1);
        assert(recording.snapshot[@"totalCPU"] == nil);
        Record(recording, off, 109, 4, 0.2);
        Metric(recording.snapshot, @"totalCPU", 35);
        Record(recording, off, 113, 5, 0.6);
        assert(recording.snapshot[@"totalCPU"] == nil); // Four-second gap is not idle.
        Record(recording, off, 114, 5.25, 0.85);
        Metric(recording.snapshot, @"totalCPU", 50);
        NSDictionary *future = @{@"host": Raw(115, 5.5, 64), @"guest:PRIVATE-container": Raw(117, 1, 128)};
        [recording recordSamples:future sync:off atTime:115 thermalState:1 lowPowerMode:NO now:116];
        Metric(recording.snapshot, @"memoryCoverage", 1);

        // A changed sync epoch isolates the averages, peaks, reply stats and pending old round.
        NSMutableDictionary *on = [Sync(2, 2, YES) mutableCopy];
        [on addEntriesFromDictionary:@{@"responseSamples": @5, @"responseP50Ms": @12, @"responseP95Ms": @20, @"packets": @5}];
        NSUInteger before = recording.sampleCount;
        assert([recording prepareForProcesses:processes sync:on atTime:120]);
        Metric(recording.snapshot, @"segment", 2);
        assert(recording.snapshot[@"averageCPU"] == nil && recording.snapshot[@"peakCPU"] == nil);
        Record(recording, off, 114, 5.25, 0.85);
        assert(recording.sampleCount == before);
        Record(recording, on, 120, 10, 20);
        assert(recording.snapshot[@"totalCPU"] == nil);
        Record(recording, on, 121, 10.5, 20.25);
        Metric(recording.snapshot, @"averageCPU", 75);
        Metric(recording.snapshot, @"peakCPU", 75);
        Metric(recording.snapshot, @"segmentElapsed", 1);
        Metric(recording.snapshot, @"elapsed", 21);
        Metric(recording.snapshot[@"sync"], @"responseP95Ms", 20);
        on[@"packets"] = @6;
        assert(![recording prepareForProcesses:processes sync:on atTime:122]);
        // Published/retained sync values must not change with the live snapshot.
        Metric(recording.snapshot[@"sync"], @"packets", 5);

        // Same PID/container, different peer identity: no CPU interval crosses a process restart.
        NSDictionary *relaunched = Identity(54321, 2, 1, @"source", [NSObject new]);
        NSDictionary *newProcesses = @{@"host": host, @"guest:PRIVATE-container": relaunched};
        assert([recording prepareForProcesses:newProcesses sync:on atTime:125]);
        Metric(recording.snapshot, @"segment", 3);
        before = recording.sampleCount;
        Record(recording, on, 121, 10.5, 20.25);
        assert(recording.sampleCount == before);
        Record(recording, on, 125, 11, 0.05);
        assert(recording.snapshot[@"totalCPU"] == nil);
        Record(recording, on, 126, 11.25, 0.15);
        Metric(recording.snapshot, @"averageCPU", 35);
        readings = recording.snapshot[@"processes"];
        Metric(readings[1], @"number", 2);
        Metric(readings[1], @"cpuInterval", 1);

        NSMutableDictionary *moved = relaunched.mutableCopy;
        moved[@"window"] = @2;
        moved[@"role"] = @"follower";
        NSDictionary *movedProcesses = @{@"host": host, @"guest:PRIVATE-container": moved.copy};
        assert([recording prepareForProcesses:movedProcesses sync:on atTime:130]);
        Metric(recording.snapshot, @"segment", 4);
        Record(recording, on, 130, 12, 1);
        Record(recording, on, 131, 12.25, 1.25);
        Metric(recording.snapshot, @"averageCPU", 50);
        NSDictionary *hostOnly = @{@"host": host};
        assert([recording prepareForProcesses:hostOnly sync:on atTime:140]);
        Record(recording, on, 140, 20, NAN);
        Record(recording, on, 141, 20.5, NAN);
        Metric(recording.snapshot, @"processCount", 1);
        Metric(recording.snapshot, @"averageCPU", 50);

        // Suspension freezes the report, then starts a warm segment after foregrounding.
        NSDictionary *frozen = recording.snapshot;
        before = recording.sampleCount;
        [recording suspend];
        assert(recording.snapshot == frozen);
        Record(recording, on, 180, 25, NAN);
        assert(recording.sampleCount == before);
        assert([recording prepareForProcesses:hostOnly sync:on atTime:200]);
        Metric(recording.snapshot, @"segment", 6);
        Record(recording, on, 200, 30, NAN);
        assert(recording.snapshot[@"totalCPU"] == nil);
        Record(recording, on, 201, 30.25, NAN);
        Metric(recording.snapshot, @"averageCPU", 25);
        Metric(recording.snapshot, @"measuredSeconds", 1);

        NSDictionary *metadata = @{@"build": @"Release (測試,\"quoted\")\nline 2", @"ios": @"27.0", @"cpus": @6, @"account": @"PRIVATE-account"};
        NSString *report = [recording csvReportWithMetadata:metadata];
        assert([report hasPrefix:@"schema_version,build,ios_version,logical_cpus,sample,segment,"]);
        assert(![report containsString:@"PRIVATE"]);
        assert(![report containsString:@"12345"] && ![report containsString:@"54321"]);
        NSDictionary *formula = @{@"build": @"=SUM(1)", @"ios": @"27.0", @"cpus": @6};
        assert([[recording csvReportWithMetadata:formula] containsString:@"'=SUM(1)"]);
        if (argc == 2) Write(report, [NSString stringWithUTF8String:argv[1]]);

        [recording resetAtTime:300];
        assert(recording.sampleCount == 0 && recording.snapshot.count == 0);
        NSString *empty = [recording csvReportWithMetadata:metadata];
        assert([empty componentsSeparatedByString:@"\r\n"].count == 2); // Header only.
        assert([recording prepareForProcesses:hostOnly sync:off atTime:300]);
        for (int i = 0; i < 305; i++) Record(recording, off, 300 + i, 40 + i * 0.25, NAN);
        assert(recording.sampleCount == 300);
        Metric(recording.snapshot, @"sample", 305);
        Metric(recording.snapshot, @"segment", 1);
        Metric(recording.snapshot, @"averageCPU", 25);
        if (argc == 2) Write([recording csvReportWithMetadata:metadata], [[NSString stringWithUTF8String:argv[1]] stringByAppendingString:@".bounded.csv"]);
        puts("Performance recording tests passed (weighted coverage, context changes, restart, suspension, captured metadata, private data exclusion and bounded rounds).");
    }
    return 0;
}
