#import "../MultitaskSupport/TapSyncSession.h"
#include <assert.h>
#include <stdio.h>

static NSDictionary *tap(double time) {
    return LCTapSyncEncode((LCTapSyncSample){0.5, 0.25, 200, 400, time, 0.1, 1, 1});
}

int main(void) {
    @autoreleasepool {
        assert([[LCTapSyncSession alloc] initWithSource:@"A" targets:@[]] == nil);
        assert([[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"A"]] == nil);
        assert(([[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B", @"B"]] == nil));
        LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B", @"C"]];
        assert(session && session.valid);
        assert([session enqueue:tap(100) fromSource:@"B" session:session.identifier sequence:1 now:100] == LCTapSyncResultStopped);
        assert([session enqueue:tap(100) fromSource:@"A" session:@"old-session" sequence:1 now:100] == LCTapSyncResultStopped);
        assert(session.pendingCount == 0);
        NSMutableDictionary *invalid = tap(100).mutableCopy;
        invalid[@"x"] = @"0.5";
        assert(!LCTapSyncDecode(invalid, NULL));
        invalid = tap(100).mutableCopy;
        invalid[@"orientation"] = @1.5;
        assert(!LCTapSyncDecode(invalid, NULL));
        invalid = tap(100).mutableCopy;
        invalid[@"tapCount"] = @(INFINITY);
        assert(!LCTapSyncDecode(invalid, NULL));
        assert([session enqueue:tap(99) fromSource:@"A" session:session.identifier sequence:1 now:100] == LCTapSyncResultExpired);
        assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:2 now:100] == LCTapSyncResultExpired);
        for (uint64_t sequence = 1; sequence <= 4; sequence++) {
            assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:sequence now:100] == LCTapSyncResultAccepted);
        }
        assert(session.pendingCount == 4);
        assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:5 now:100] == LCTapSyncResultBusy);
        LCTapSyncResult result;
        for (uint64_t sequence = 1; sequence <= 4; sequence++) {
            NSDictionary *next = [session takeNextAtTime:100.1 result:&result];
            assert(result == LCTapSyncResultAccepted && [next[@"sequence"] unsignedLongLongValue] == sequence);
        }
        assert([session takeNextAtTime:100.1 result:&result] == nil && result == LCTapSyncResultAccepted);
        assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:4 now:100.2] == LCTapSyncResultExpired);
        assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:5 now:100.2] == LCTapSyncResultAccepted);
        assert([session takeNextAtTime:100.76 result:&result] == nil && result == LCTapSyncResultExpired);
        assert(!session.valid && session.pendingCount == 0);
        assert([session enqueue:tap(101) fromSource:@"A" session:session.identifier sequence:6 now:101] == LCTapSyncResultStopped);
        LCTapSyncSession *nextSession = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"]];
        assert(![nextSession.identifier isEqualToString:session.identifier]);
        assert([nextSession enqueue:tap(101) fromSource:@"A" session:session.identifier sequence:1 now:101] == LCTapSyncResultStopped);
        assert([nextSession enqueue:tap(101) fromSource:@"A" session:nextSession.identifier sequence:1 now:101] == LCTapSyncResultAccepted);
        [nextSession invalidate];
        assert(nextSession.pendingCount == 0 && !nextSession.valid);
        assert([nextSession takeNextAtTime:101 result:&result] == nil && result == LCTapSyncResultStopped);
        puts("Tap sync session tests passed (identity, malformed input, ordering, bounded queues, expiry, pause and old sessions).");
    }
    return 0;
}
