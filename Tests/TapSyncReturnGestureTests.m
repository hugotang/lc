#import "../TweakLoader/TapSyncReturnGesture.h"
#include <assert.h>
#include <stdio.h>

static LCTouchSyncSample sample(uint32_t contact, LCTouchSyncPhase phase, double time) {
    return (LCTouchSyncSample){0.4, 0.5, 200, 400, time, contact, 1, 1, phase};
}

static void testCompleteTapAndExpiry(void) {
    assert(![[LCTapSyncReturnGesture alloc] initWithMode:(LCTapSyncMode)99 revision:7 atTime:10]);
    assert(![[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeTapsOnly revision:0 atTime:10]);
    assert(![[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeTapsOnly revision:7 atTime:NAN]);
    LCTapSyncReturnGesture *gesture = [[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeTapsOnly revision:7 atTime:10];
    assert(gesture.revision == 7 && !gesture.hasActiveContacts && gesture.packets.count == 0);
    assert(![gesture appendTap:LCTapSyncEncode((LCTapSyncSample){0.4, 0.5, 200, 400, 9.9, 0.05, 1, 1})]);
    assert([gesture appendTap:LCTapSyncEncode((LCTapSyncSample){0.4, 0.5, 200, 400, 10.05, 0.05, 1, 1})]);
    assert(gesture.packets.count == 1);
    assert(![gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseBegan, 10))]);
    assert([gesture isFreshAtTime:10.7]);
    assert(![gesture isFreshAtTime:10.76]);
    assert(![gesture isFreshAtTime:9]);
    assert(![gesture isFreshAtTime:NAN]);
}

static void testSingleFingerBoundariesAndMoves(void) {
    LCTapSyncReturnGesture *gesture = [[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeSingleFinger revision:2 atTime:10];
    assert(![gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseMoved, 10))]);
    assert([gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseBegan, 10))]);
    assert(gesture.hasActiveContacts);
    for (unsigned i = 1; i <= 100; i++) assert([gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseMoved, 10 + i * 0.001))]);
    assert(gesture.packets.count == 2); // Preserve began; coalesce only consecutive moves.
    assert([gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseEnded, 10.2))]);
    assert(!gesture.hasActiveContacts && gesture.packets.count == 3);
    LCTouchSyncSample first, last;
    assert(LCTouchSyncDecode(gesture.packets.firstObject[@"touch"], &first) && first.phase == LCTouchSyncPhaseBegan);
    assert(LCTouchSyncDecode(gesture.packets.lastObject[@"touch"], &last) && last.phase == LCTouchSyncPhaseEnded);
    assert(![gesture appendTouch:LCTouchSyncEncode(sample(1, LCTouchSyncPhaseBegan, 10.3))]);
}

static void testTwoFingerAtomicReturn(void) {
    LCTapSyncReturnGesture *gesture = [[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeTwoFingers revision:1 atTime:10];
    LCMultiTouchSyncFrame frame = {.width=200, .height=400, .timestamp=10, .orientation=1, .count=2,
        .contacts={{0.2, 0.5, 1, 1, LCMultiTouchSyncPhaseBegan}, {0.8, 0.5, 2, 1, LCMultiTouchSyncPhaseBegan}}};
    assert([gesture appendFrame:LCMultiTouchSyncEncode(frame)]);
    assert(gesture.hasActiveContacts);
    frame.timestamp += 0.01;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseMoved;
    frame.contacts[1].phase = LCMultiTouchSyncPhaseStationary;
    assert([gesture appendFrame:LCMultiTouchSyncEncode(frame)]);
    frame.timestamp += 0.01;
    frame.contacts[0].phase = LCMultiTouchSyncPhaseStationary;
    frame.contacts[1].phase = LCMultiTouchSyncPhaseMoved;
    assert([gesture appendFrame:LCMultiTouchSyncEncode(frame)]);
    assert(gesture.packets.count == 2);
    LCMultiTouchSyncFrame queued;
    assert(LCMultiTouchSyncDecode(gesture.packets.lastObject[@"frame"], &queued));
    assert(queued.contacts[0].phase == LCMultiTouchSyncPhaseMoved && queued.contacts[1].phase == LCMultiTouchSyncPhaseMoved);
    frame.timestamp += 0.01;
    frame.contacts[0].phase = frame.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
    assert([gesture appendFrame:LCMultiTouchSyncEncode(frame)]);
    assert(!gesture.hasActiveContacts && gesture.packets.count == 3);
}

static void testBoundedBufferPreservesOldPackets(void) {
    LCTapSyncReturnGesture *gesture = [[LCTapSyncReturnGesture alloc] initWithMode:LCTapSyncModeSingleFinger revision:1 atTime:10];
    for (unsigned contact = 1; contact <= 32; contact++) {
        assert([gesture appendTouch:LCTouchSyncEncode(sample(contact, LCTouchSyncPhaseBegan, 10 + contact * 0.01))]);
        assert([gesture appendTouch:LCTouchSyncEncode(sample(contact, LCTouchSyncPhaseEnded, 10 + contact * 0.01 + 0.001))]);
    }
    NSArray *before = gesture.packets;
    assert(![gesture appendTouch:LCTouchSyncEncode(sample(33, LCTouchSyncPhaseBegan, 10.4))]);
    assert([gesture.packets isEqual:before] && !gesture.hasActiveContacts);
}

int main(void) {
    @autoreleasepool {
        testCompleteTapAndExpiry();
        testSingleFingerBoundariesAndMoves();
        testTwoFingerAtomicReturn();
        testBoundedBufferPreservesOldPackets();
        puts("Tap sync first-return gesture buffer tests passed");
    }
    return 0;
}
