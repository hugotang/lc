#include "../MultitaskSupport/TouchSyncGeometry.h"
#include <assert.h>
#include <stdio.h>

static LCTouchSyncSample sample(uint32_t contact, LCTouchSyncPhase phase, double timestamp) {
    return (LCTouchSyncSample){0.25, 0.75, 200, 400, timestamp, contact, 1, 1, phase};
}

int main(void) {
    LCTouchSyncSample touch = sample(1, LCTouchSyncPhaseBegan, 100);
    assert(LCTouchSyncSampleIsValid(touch));
    assert(LCTouchSyncSampleIsFresh(touch, 100.75));
    assert(!LCTouchSyncSampleIsFresh(touch, 100.751));
    assert(!LCTouchSyncSampleIsFresh(touch, 99.999));
    assert(!LCTouchSyncSampleIsFresh(touch, NAN));
    assert(LCTouchSyncCanMap(touch, 400, 800, 1));
    assert(!LCTouchSyncCanMap(touch, 400, 200, 1));
    assert(!LCTouchSyncCanMap(touch, 200, 400, 2));
    assert(!LCTouchSyncCanMap(touch, NAN, 400, 1));
    touch.x = 1;
    assert(!LCTouchSyncSampleIsValid(touch));
    touch.phase = LCTouchSyncPhaseMoved;
    assert(LCTouchSyncSampleIsValid(touch));
    touch.x = -0.1;
    assert(LCTouchSyncSampleIsValid(touch));
    touch.x = 2.001;
    assert(!LCTouchSyncSampleIsValid(touch));
    touch.x = NAN;
    assert(!LCTouchSyncSampleIsValid(touch));
    touch.x = 0.5;
    touch.phase = (LCTouchSyncPhase)-1;
    assert(!LCTouchSyncSampleIsValid(touch));
    touch.phase = (LCTouchSyncPhase)4;
    assert(!LCTouchSyncSampleIsValid(touch));
    touch = sample(0, LCTouchSyncPhaseBegan, 100);
    assert(!LCTouchSyncSampleIsValid(touch));
    touch = sample(1, LCTouchSyncPhaseBegan, INFINITY);
    assert(!LCTouchSyncSampleIsValid(touch));

    LCTouchSyncStream stream = {0};
    assert(!LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseMoved, 100)));
    assert(!LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseEnded, 100)));
    assert(LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseBegan, 100)));
    assert(!LCTouchSyncAdvance(&stream, sample(2, LCTouchSyncPhaseBegan, 100.1)));
    assert(!LCTouchSyncAdvance(&stream, sample(2, LCTouchSyncPhaseMoved, 100.1)));
    assert(!LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseMoved, 99.9)));
    touch = sample(1, LCTouchSyncPhaseMoved, 100.1);
    touch.width *= 2;
    touch.height *= 2;
    assert(!LCTouchSyncAdvance(&stream, touch));
    touch = sample(1, LCTouchSyncPhaseMoved, 100.1);
    touch.orientation = 2;
    assert(!LCTouchSyncAdvance(&stream, touch));
    touch = sample(1, LCTouchSyncPhaseMoved, 100.1);
    touch.tapCount = 2;
    assert(!LCTouchSyncAdvance(&stream, touch));
    assert(stream.contact == 1 && stream.lastContact == 1 && stream.timestamp == 100);

    // A long hold needs no keepalive moves; only the new release packet must be fresh.
    touch = sample(1, LCTouchSyncPhaseEnded, 160);
    touch.x = -0.1;
    assert(LCTouchSyncSampleIsFresh(touch, 160.1));
    assert(LCTouchSyncAdvance(&stream, touch));
    assert(stream.contact == 0);
    assert(!LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseBegan, 161)));
    assert(!LCTouchSyncAdvance(&stream, sample(1, LCTouchSyncPhaseMoved, 161)));
    assert(LCTouchSyncAdvance(&stream, sample(2, LCTouchSyncPhaseBegan, 161)));
    for (int i = 1; i <= 120; i++) {
        touch = sample(2, LCTouchSyncPhaseMoved, 161 + i / 120.0);
        touch.x = i / 120.0;
        assert(LCTouchSyncAdvance(&stream, touch));
    }
    assert(LCTouchSyncAdvance(&stream, sample(2, LCTouchSyncPhaseCancelled, 162)));
    assert(stream.contact == 0 && stream.lastContact == 2);
    assert(!LCTouchSyncAdvance(&stream, sample(2, LCTouchSyncPhaseEnded, 162.1)));
    assert(LCTouchSyncAdvance(&stream, sample(3, LCTouchSyncPhaseBegan, 163)));
    assert(LCTouchSyncAdvance(&stream, sample(3, LCTouchSyncPhaseEnded, 163.01)));
    puts("Single-finger geometry tests passed (mapping, outside tracking, contact identity, long holds, moves, cancellation and invalid transitions).");
    return 0;
}
