#include "../MultitaskSupport/MultiTouchSyncGeometry.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static LCMultiTouchSyncContact contact(uint32_t identifier, double x, LCMultiTouchSyncPhase phase) {
    return (LCMultiTouchSyncContact){x, 0.5, identifier, 1, phase};
}
static LCMultiTouchSyncFrame pair(double time, LCMultiTouchSyncPhase a, LCMultiTouchSyncPhase b) {
    LCMultiTouchSyncFrame frame = {.width = 200, .height = 400, .timestamp = time, .orientation = 1, .count = 2};
    frame.contacts[0] = contact(1, 0.2, a);
    frame.contacts[1] = contact(2, 0.8, b);
    return frame;
}
static void rejected(LCMultiTouchSyncStream *stream, LCMultiTouchSyncFrame frame) {
    LCMultiTouchSyncStream original = *stream;
    assert(!LCMultiTouchSyncAdvance(stream, frame));
    assert(memcmp(stream, &original, sizeof(original)) == 0);
}
int main(void) {
    LCMultiTouchSyncFrame began = pair(100, LCMultiTouchSyncPhaseBegan, LCMultiTouchSyncPhaseBegan);
    assert(LCMultiTouchSyncFrameIsValid(began));
    assert(LCMultiTouchSyncFrameIsFresh(began, 100.75));
    assert(!LCMultiTouchSyncFrameIsFresh(began, 100.751));
    assert(!LCMultiTouchSyncFrameIsFresh(began, 99.9));
    assert(LCMultiTouchSyncCanMap(began, 400, 800, 1));
    assert(!LCMultiTouchSyncCanMap(began, 400, 200, 1));
    assert(!LCMultiTouchSyncCanMap(began, 200, 400, 2));
    LCMultiTouchSyncStream source = {0}, receiver = {0};
    assert(LCMultiTouchSyncAdvance(&source, began));
    assert(LCMultiTouchSyncAdvance(&receiver, began));
    assert(source.count == 2 && source.lastContact == 2);
    rejected(&source, began);

    LCMultiTouchSyncFrame a = pair(100.01, LCMultiTouchSyncPhaseMoved, LCMultiTouchSyncPhaseStationary);
    a.contacts[0].x = 0.3;
    assert(LCMultiTouchSyncAdvance(&source, a));
    LCMultiTouchSyncFrame b = pair(100.02, LCMultiTouchSyncPhaseStationary, LCMultiTouchSyncPhaseMoved);
    b.contacts[0].x = 0.3;
    b.contacts[1].x = 0.7;
    assert(LCMultiTouchSyncAdvance(&source, b));
    assert(LCMultiTouchSyncCoalesce(a, &b));
    assert(b.contacts[0].phase == LCMultiTouchSyncPhaseMoved);
    assert(LCMultiTouchSyncAdvance(&receiver, b));
    assert(receiver.contacts[0].x == 0.3 && receiver.contacts[1].x == 0.7);
    assert(!LCMultiTouchSyncCoalesce(began, &b));
    assert(!LCMultiTouchSyncCoalesce(b, &began));

    LCMultiTouchSyncFrame invalid = b;
    invalid.count = 1; // A live second finger disappeared.
    rejected(&source, invalid);
    invalid = b; invalid.contacts[1].identifier = 1;
    rejected(&source, invalid);
    invalid = b; invalid.contacts[1].tapCount = 2;
    rejected(&source, invalid);
    invalid = b; invalid.orientation = 3;
    rejected(&source, invalid);
    invalid = b; invalid.timestamp = 99;
    rejected(&source, invalid);
    invalid = b; invalid.contacts[0].x = NAN;
    rejected(&source, invalid);
    invalid = b; invalid.width = INFINITY;
    rejected(&source, invalid);
    invalid = b; invalid.contacts[0].x = 0.4; invalid.contacts[0].phase = LCMultiTouchSyncPhaseStationary;
    rejected(&source, invalid);
    invalid = b; invalid.contacts[0].phase = invalid.contacts[1].phase = LCMultiTouchSyncPhaseStationary;
    rejected(&source, invalid); // No stationary keepalive packets.
    invalid = b; invalid.count = 3; invalid.contacts[2] = contact(3, 0.5, LCMultiTouchSyncPhaseBegan);
    rejected(&source, invalid); // Third simultaneous finger.

    // Hold finger 1 while releasing and repeatedly replacing finger 2 (joystick + button).
    b.timestamp = 160;
    b.contacts[0].phase = LCMultiTouchSyncPhaseStationary;
    b.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
    assert(LCMultiTouchSyncFrameIsFresh(b, 160.1));
    assert(LCMultiTouchSyncAdvance(&source, b));
    assert(LCMultiTouchSyncAdvance(&receiver, b));
    assert(source.count == 1 && source.contacts[0].identifier == 1);
    b.timestamp = 161;
    b.contacts[1] = contact(3, 0.7, LCMultiTouchSyncPhaseBegan);
    assert(LCMultiTouchSyncAdvance(&source, b));
    assert(LCMultiTouchSyncAdvance(&receiver, b));
    // Two old releases and two new beginnings can share one physical frame.
    b.timestamp = 162;
    b.contacts[0].phase = b.contacts[1].phase = LCMultiTouchSyncPhaseEnded;
    b.count = 4;
    b.contacts[2] = contact(4, 0.2, LCMultiTouchSyncPhaseBegan);
    b.contacts[3] = contact(5, 0.8, LCMultiTouchSyncPhaseBegan);
    assert(LCMultiTouchSyncAdvance(&source, b));
    assert(LCMultiTouchSyncAdvance(&receiver, b));
    assert(source.count == 2 && source.lastContact == 5);
    b.count = 2;
    b.timestamp = 163;
    b.contacts[0] = contact(4, -0.2, LCMultiTouchSyncPhaseCancelled);
    b.contacts[1] = contact(5, 1.2, LCMultiTouchSyncPhaseEnded);
    assert(LCMultiTouchSyncAdvance(&source, b));
    assert(LCMultiTouchSyncAdvance(&receiver, b));
    assert(source.count == 0 && source.cancelled);
    b.timestamp = 164;
    b.count = 1;
    b.contacts[0] = contact(6, 0.5, LCMultiTouchSyncPhaseBegan);
    assert(LCMultiTouchSyncAdvance(&source, b) && !source.cancelled);
    b.timestamp = 165; b.contacts[0].phase = LCMultiTouchSyncPhaseEnded;
    assert(LCMultiTouchSyncAdvance(&source, b) && source.count == 0 && !source.cancelled);
    b.timestamp = 166; b.contacts[0].phase = LCMultiTouchSyncPhaseBegan;
    rejected(&source, b); // A released identity cannot be reused in this session.
    b.contacts[0].identifier = 7; b.contacts[0].x = 1;
    rejected(&source, b);
    b.contacts[0].x = 0.5; b.count = 5;
    rejected(&source, b);
    puts("Two-finger geometry tests passed (atomic frames, pinch motion, coalescing, joystick/button replacement, holds, cancellation and invalid input).");
    return 0;
}
