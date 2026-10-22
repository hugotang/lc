#import "../MultitaskSupport/TapSyncSession.h"
#include <assert.h>
#include <stdio.h>

static NSDictionary *tap(double time) {
    return LCTapSyncEncode((LCTapSyncSample){0.5, 0.25, 200, 400, time, 0.1, 1, 1});
}

static NSDictionary *touch(uint32_t contact, LCTouchSyncPhase phase, double time) {
    return LCTouchSyncEncode((LCTouchSyncSample){0.5, 0.25, 200, 400, time, contact, 1, 1, phase});
}

static LCTapSyncResult enqueueTouch(LCTapSyncSession *session, uint64_t sequence, uint32_t contact, LCTouchSyncPhase phase, double time) {
    return [session enqueueTouch:touch(contact, phase, time) fromSource:@"A" session:session.identifier sequence:sequence now:time];
}

static void testSingleFingerSessions(void) {
    assert([[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:(LCTapSyncMode)2] == nil);
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:LCTapSyncModeSingleFinger];
    assert(session.mode == LCTapSyncModeSingleFinger);
    assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:1 now:100] == LCTapSyncResultInvalidGesture);
    assert([session enqueueTouch:touch(1, LCTouchSyncPhaseBegan, 100) fromSource:@"B" session:session.identifier sequence:1 now:100] == LCTapSyncResultStopped);
    assert([session enqueueTouch:touch(1, LCTouchSyncPhaseBegan, 100) fromSource:@"A" session:@"previous" sequence:1 now:100] == LCTapSyncResultStopped);
    for (NSString *key in @[@"contact", @"phase", @"orientation", @"tapCount"]) {
        for (id invalid in @[@"1", @(NAN), @(INFINITY), @-1, @1.5, @(UINT64_MAX)]) {
            NSMutableDictionary *packet = touch(1, LCTouchSyncPhaseBegan, 100).mutableCopy;
            packet[key] = invalid;
            assert(!LCTouchSyncDecode(packet, NULL));
        }
    }
    assert(enqueueTouch(session, 1, 1, LCTouchSyncPhaseMoved, 100) == LCTapSyncResultInvalidGesture);
    assert(enqueueTouch(session, 2, 1, LCTouchSyncPhaseBegan, 100) == LCTapSyncResultExpired);
    assert(enqueueTouch(session, 1, 1, LCTouchSyncPhaseBegan, 100) == LCTapSyncResultAccepted);
    for (uint64_t seq = 2; seq <= 100; seq++) {
        assert(enqueueTouch(session, seq, 1, LCTouchSyncPhaseMoved, 100 + seq / 1000.0) == LCTapSyncResultAccepted);
    }
    assert(session.pendingCount == 2);
    assert(enqueueTouch(session, 101, 1, LCTouchSyncPhaseEnded, 100.2) == LCTapSyncResultAccepted);
    assert(enqueueTouch(session, 102, 2, LCTouchSyncPhaseBegan, 100.21) == LCTapSyncResultAccepted);
    assert(session.pendingCount == 4);
    // Full queues reject a release rather than silently dropping a contact boundary. The caller pauses/cancels.
    assert(enqueueTouch(session, 103, 2, LCTouchSyncPhaseEnded, 100.22) == LCTapSyncResultBusy);
    LCTapSyncResult result;
    LCTouchSyncStream receiver = {0};
    NSArray<NSNumber *> *expected = @[@1, @100, @101, @102];
    for (NSNumber *sequence in expected) {
        NSDictionary *packet = [session takeNextAtTime:100.3 result:&result];
        assert(packet && result == LCTapSyncResultAccepted && [packet[@"sequence"] isEqual:sequence]);
        LCTouchSyncSample sample;
        assert(LCTouchSyncDecode(packet[@"touch"], &sample));
        assert(LCTouchSyncAdvance(&receiver, sample));
    }
    assert(receiver.contact == 2 && session.pendingCount == 0);
    // Rejected packets did not advance sequence or contact state.
    assert(enqueueTouch(session, 103, 2, LCTouchSyncPhaseCancelled, 100.4) == LCTapSyncResultAccepted);
    NSDictionary *cancel = [session takeNextAtTime:100.4 result:&result];
    LCTouchSyncSample cancelled;
    assert(LCTouchSyncDecode(cancel[@"touch"], &cancelled) && cancelled.phase == LCTouchSyncPhaseCancelled);
    assert(LCTouchSyncAdvance(&receiver, cancelled) && receiver.contact == 0);
    assert(enqueueTouch(session, 104, 2, LCTouchSyncPhaseMoved, 100.5) == LCTapSyncResultInvalidGesture);
    assert(enqueueTouch(session, 104, 3, LCTouchSyncPhaseBegan, 101) == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:101.1 result:&result] != nil);
    assert(enqueueTouch(session, 105, 3, LCTouchSyncPhaseEnded, 161) == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:161.1 result:&result] != nil);
    assert(enqueueTouch(session, 106, 4, LCTouchSyncPhaseBegan, 162) == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:162.76 result:&result] == nil && result == LCTapSyncResultExpired);
    assert(!session.valid && session.pendingCount == 0);
    assert(enqueueTouch(session, 107, 4, LCTouchSyncPhaseEnded, 163) == LCTapSyncResultStopped);

    LCTapSyncSession *next = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:LCTapSyncModeSingleFinger];
    assert([next enqueueTouch:touch(4, LCTouchSyncPhaseEnded, 164) fromSource:@"A" session:session.identifier sequence:1 now:164] == LCTapSyncResultStopped);
    assert(enqueueTouch(next, 1, 1, LCTouchSyncPhaseBegan, 164) == LCTapSyncResultAccepted);
    [next invalidate];
    assert([next takeNextAtTime:164 result:&result] == nil && result == LCTapSyncResultStopped);
    LCTapSyncSession *taps = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"]];
    assert(enqueueTouch(taps, 1, 1, LCTouchSyncPhaseBegan, 164) == LCTapSyncResultInvalidGesture);
}

int main(void) {
    @autoreleasepool {
        testSingleFingerSessions();
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
        puts("Input sync session tests passed (identity, modes, malformed input, ordering, coalescing, contact boundaries, bounded queues, holds, expiry and stopped sessions).");
    }
    return 0;
}
