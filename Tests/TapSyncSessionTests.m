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
    assert([[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:(LCTapSyncMode)3] == nil);
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

static LCTapSyncResult enqueueFrame(LCTapSyncSession *session, uint64_t sequence, LCMultiTouchSyncFrame frame) {
    return [session enqueueTouchFrame:LCMultiTouchSyncEncode(frame) fromSource:@"A" session:session.identifier sequence:sequence now:frame.timestamp];
}

static void testTwoFingerSessions(void) {
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B", @"C"] mode:LCTapSyncModeTwoFingers];
    assert(session && session.mode == LCTapSyncModeTwoFingers);
    LCMultiTouchSyncFrame frame = {.width = 200, .height = 400, .timestamp = 100, .orientation = 1, .count = 2,
        .contacts = {{0.2, 0.5, 1, 1, LCMultiTouchSyncPhaseBegan}, {0.8, 0.5, 2, 1, LCMultiTouchSyncPhaseBegan}}};
    NSDictionary *encoded = LCMultiTouchSyncEncode(frame);
    assert(LCMultiTouchSyncDecode(encoded, NULL));
    assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:1 now:100] == LCTapSyncResultInvalidGesture);
    assert(enqueueTouch(session, 1, 1, LCTouchSyncPhaseBegan, 100) == LCTapSyncResultInvalidGesture);
    assert([session enqueueTouchFrame:encoded fromSource:@"C" session:session.identifier sequence:1 now:100] == LCTapSyncResultStopped);
    assert([session enqueueTouchFrame:encoded fromSource:@"A" session:@"old" sequence:1 now:100] == LCTapSyncResultStopped);
    assert([session enqueueTouchFrame:encoded fromSource:@"A" session:session.identifier sequence:1 now:101] == LCTapSyncResultExpired);
    for (id invalid in @[NSNull.null, @"bad", @[], @[encoded, encoded, encoded, encoded, encoded]]) {
        NSMutableDictionary *packet = encoded.mutableCopy;
        packet[@"contacts"] = invalid;
        assert(!LCMultiTouchSyncDecode(packet, NULL));
    }
    for (NSString *key in @[@"contact", @"phase", @"tapCount"]) {
        for (id invalid in @[@"1", @(NAN), @(INFINITY), @-1, @1.5, @(UINT64_MAX)]) {
            NSMutableDictionary *packet = encoded.mutableCopy;
            NSMutableArray *contacts = [encoded[@"contacts"] mutableCopy];
            NSMutableDictionary *first = [contacts[0] mutableCopy];
            first[key] = invalid;
            contacts[0] = first;
            packet[@"contacts"] = contacts;
            assert(!LCMultiTouchSyncDecode(packet, NULL));
        }
    }
    LCTapSyncSession *single = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:LCTapSyncModeSingleFinger];
    assert(enqueueFrame(single, 1, frame) == LCTapSyncResultInvalidGesture);
    assert(enqueueFrame(session, 2, frame) == LCTapSyncResultExpired);
    assert(enqueueFrame(session, 1, frame) == LCTapSyncResultAccepted);
    for (uint64_t sequence = 2; sequence <= 99; sequence++) {
        frame.timestamp = 100 + sequence / 1000.0;
        unsigned moving = (unsigned)(sequence % 2);
        frame.contacts[moving].x += 0.001;
        frame.contacts[moving].phase = LCMultiTouchSyncPhaseMoved;
        frame.contacts[1 - moving].phase = LCMultiTouchSyncPhaseStationary;
        assert(enqueueFrame(session, sequence, frame) == LCTapSyncResultAccepted);
    }
    assert(session.pendingCount == 2 && session.coalescedMoveCount == 97);
    frame.timestamp = 100.2;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseStationary;
    frame.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
    assert(enqueueFrame(session, 100, frame) == LCTapSyncResultAccepted);
    frame.timestamp = 100.21;
    frame.contacts[1].identifier = 3;
    frame.contacts[1].phase = LCMultiTouchSyncPhaseBegan;
    assert(enqueueFrame(session, 101, frame) == LCTapSyncResultAccepted);
    assert(session.pendingCount == 4);
    frame.timestamp = 100.22;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseCancelled;
    frame.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
    assert(enqueueFrame(session, 102, frame) == LCTapSyncResultBusy);
    LCTapSyncResult result;
    LCMultiTouchSyncStream receiver = {0};
    for (NSNumber *sequence in @[@1, @99, @100, @101]) {
        NSDictionary *packet = [session takeNextAtTime:100.25 result:&result];
        assert(packet && result == LCTapSyncResultAccepted && [packet[@"sequence"] isEqual:sequence]);
        LCMultiTouchSyncFrame received;
        assert(LCMultiTouchSyncDecode(packet[@"frame"], &received));
        assert(LCMultiTouchSyncAdvance(&receiver, received));
        assert(![packet[@"completed"] boolValue]);
    }
    assert(receiver.count == 2 && receiver.lastContact == 3);
    assert(enqueueFrame(session, 102, frame) == LCTapSyncResultAccepted);
    NSDictionary *cancel = [session takeNextAtTime:100.25 result:&result];
    assert(![cancel[@"completed"] boolValue]);
    frame.count = 1;
    frame.timestamp = 101;
    frame.contacts[0].identifier = 4;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseBegan;
    assert(enqueueFrame(session, 103, frame) == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:101 result:&result]);
    frame.timestamp = 161;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseEnded;
    assert(enqueueFrame(session, 104, frame) == LCTapSyncResultAccepted);
    assert([[session takeNextAtTime:161 result:&result][@"completed"] boolValue]);
    frame.timestamp = 162;
    frame.contacts[0].identifier = 5;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseBegan;
    assert(enqueueFrame(session, 105, frame) == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:163 result:&result] == nil && result == LCTapSyncResultExpired);
    assert(!session.valid && session.pendingCount == 0);
    assert(enqueueFrame(session, 106, frame) == LCTapSyncResultStopped);
}

static void testAtomicFirstReturnAndLiveContinuation(void) {
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:LCTapSyncModeSingleFinger];
    NSMutableArray *packets = [NSMutableArray array];
    for (unsigned contact = 1; contact <= 3; contact++) {
        [packets addObject:@{@"touch": touch(contact, LCTouchSyncPhaseBegan, 100 + contact * 0.01)}];
        [packets addObject:@{@"touch": touch(contact, LCTouchSyncPhaseEnded, 100 + contact * 0.01 + 0.001)}];
    }
    [packets addObject:@{@"touch": touch(4, LCTouchSyncPhaseBegan, 100.04)}];
    NSArray *invalid = [packets arrayByAddingObject:@{@"touch": touch(8, LCTouchSyncPhaseMoved, 100.05)}];
    assert([session enqueueSourceReturn:invalid fromSource:@"A" session:session.identifier now:100.1] == LCTapSyncResultInvalidGesture);
    assert(session.valid && session.pendingCount == 0);
    assert([session enqueueSourceReturn:packets fromSource:@"B" session:session.identifier now:100.1] == LCTapSyncResultStopped);
    assert([session enqueueSourceReturn:packets fromSource:@"A" session:session.identifier now:101] == LCTapSyncResultExpired);
    assert(session.pendingCount == 0);
    assert([session enqueueSourceReturn:packets fromSource:@"A" session:session.identifier now:100.1] == LCTapSyncResultAccepted);
    assert(session.pendingCount == 7);
    assert([session enqueueSourceReturn:packets fromSource:@"A" session:session.identifier now:100.1] == LCTapSyncResultInvalidGesture);
    assert(enqueueTouch(session, 8, 4, LCTouchSyncPhaseMoved, 100.11) == LCTapSyncResultAccepted);
    assert(enqueueTouch(session, 9, 4, LCTouchSyncPhaseEnded, 100.12) == LCTapSyncResultAccepted);
    assert(enqueueTouch(session, 10, 5, LCTouchSyncPhaseBegan, 100.13) == LCTapSyncResultAccepted);
    assert(enqueueTouch(session, 11, 5, LCTouchSyncPhaseEnded, 100.14) == LCTapSyncResultAccepted);
    assert(enqueueTouch(session, 12, 6, LCTouchSyncPhaseBegan, 100.15) == LCTapSyncResultBusy);
    assert(session.pendingCount == 11);
    LCTouchSyncStream stream = {0};
    LCTapSyncResult result;
    for (uint64_t sequence = 1; sequence <= 11; sequence++) {
        NSDictionary *packet = [session takeNextAtTime:100.2 result:&result];
        assert(result == LCTapSyncResultAccepted && [packet[@"sequence"] unsignedLongLongValue] == sequence);
        LCTouchSyncSample sample;
        assert(LCTouchSyncDecode(packet[@"touch"], &sample) && LCTouchSyncAdvance(&stream, sample));
    }
    assert(stream.contact == 0 && session.pendingCount == 0);
    [session invalidate];
    assert([session enqueueSourceReturn:@[] fromSource:@"A" session:session.identifier now:100.2] == LCTapSyncResultStopped);

    // Tap-only recovery can finish preparing while its first physical finger is
    // still down. An empty capture establishes the barrier; the tap follows live.
    session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"]];
    assert([session enqueueSourceReturn:@[] fromSource:@"A" session:session.identifier now:100] == LCTapSyncResultAccepted);
    assert([session enqueue:tap(100) fromSource:@"A" session:session.identifier sequence:1 now:100] == LCTapSyncResultAccepted);
    assert([session takeNextAtTime:100.1 result:&result] != nil);
}

static void testPreparationResults(void) {
    LCTapSyncPreparation *preparation = [[LCTapSyncPreparation alloc] initWithContainers:@[@"B", @"C", @"D"]];
    assert([preparation recordResult:LCTapSyncResultSceneInactive forContainer:@"D"]);
    assert(preparation.pendingContainers.count == 2);
    assert([preparation recordResult:LCTapSyncResultKeyboardVisible forContainer:@"B"]);
    assert(![preparation recordResult:LCTapSyncResultAccepted forContainer:@"B"]);
    assert(![preparation recordResult:LCTapSyncResultAccepted forContainer:@"unknown"]);
    NSDictionary *timeout = preparation.failuresIncludingTimeouts;
    assert(timeout.count == 3);
    assert([timeout[@"D"] integerValue] == LCTapSyncResultSceneInactive);
    assert([timeout[@"B"] integerValue] == LCTapSyncResultKeyboardVisible);
    assert([timeout[@"C"] integerValue] == LCTapSyncResultPreparationTimedOut);
    assert([preparation recordResult:LCTapSyncResultSceneInactive forContainer:@"C"]);
    assert(preparation.pendingContainers.count == 0 && preparation.failures.count == 3);

    preparation = [[LCTapSyncPreparation alloc] initWithContainers:@[@"B", @"C"]];
    assert([preparation recordResult:LCTapSyncResultAccepted forContainer:@"C"]);
    assert(preparation.pendingContainers.count == 1 && preparation.failures.count == 0);
    assert(preparation.failuresIncludingTimeouts.count == 1);
    assert([preparation recordResult:LCTapSyncResultAccepted forContainer:@"B"]);
    assert(preparation.pendingContainers.count == 0 && preparation.failuresIncludingTimeouts.count == 0);
}

static void testAtomicTwoFingerReturnRetainsMoreThanFourBoundaries(void) {
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:@"A" targets:@[@"B"] mode:LCTapSyncModeTwoFingers];
    LCMultiTouchSyncFrame frame = {.width=200, .height=400, .timestamp=100, .orientation=1, .count=1,
        .contacts={{0.2, 0.5, 1, 1, LCMultiTouchSyncPhaseBegan}}};
    NSMutableArray *packets = [NSMutableArray arrayWithObject:@{@"frame": LCMultiTouchSyncEncode(frame)}];
    for (unsigned contact = 2; contact <= 4; contact++) {
        frame.timestamp += 0.01;
        frame.count = 2;
        frame.contacts[0].phase = LCMultiTouchSyncPhaseStationary;
        frame.contacts[1] = (LCMultiTouchSyncContact){0.8, 0.5, contact, 1, LCMultiTouchSyncPhaseBegan};
        [packets addObject:@{@"frame": LCMultiTouchSyncEncode(frame)}];
        frame.timestamp += 0.01;
        frame.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
        [packets addObject:@{@"frame": LCMultiTouchSyncEncode(frame)}];
    }
    frame.timestamp += 0.01;
    frame.count = 1;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseEnded;
    [packets addObject:@{@"frame": LCMultiTouchSyncEncode(frame)}];
    assert(packets.count == 8);
    NSArray *invalid = [packets arrayByAddingObject:packets.lastObject];
    assert([session enqueueSourceReturn:invalid fromSource:@"A" session:session.identifier now:100.1] == LCTapSyncResultInvalidGesture);
    assert(session.pendingCount == 0);
    assert([session enqueueSourceReturn:packets fromSource:@"A" session:session.identifier now:100.1] == LCTapSyncResultAccepted);
    LCMultiTouchSyncStream stream = {0};
    LCTapSyncResult result;
    for (NSUInteger index = 0; index < packets.count; index++) {
        NSDictionary *packet = [session takeNextAtTime:100.2 result:&result];
        assert(packet && result == LCTapSyncResultAccepted);
        LCMultiTouchSyncFrame received;
        assert(LCMultiTouchSyncDecode(packet[@"frame"], &received) && LCMultiTouchSyncAdvance(&stream, received));
        assert([packet[@"completed"] boolValue] == (index + 1 == packets.count));
    }
    assert(stream.count == 0 && !stream.cancelled && session.pendingCount == 0);
}

int main(void) {
    @autoreleasepool {
        testSingleFingerSessions();
        testTwoFingerSessions();
        testAtomicFirstReturnAndLiveContinuation();
        testAtomicTwoFingerReturnRetainsMoreThanFourBoundaries();
        testPreparationResults();
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
