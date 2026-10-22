#include "../MultitaskSupport/TapSyncGeometry.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    LCTapSyncSample tap = {0.25, 0.75, 200, 400, 100, 0.1, 1, 1};
    assert(LCTapSyncSampleIsValid(tap));
    assert(LCTapSyncSampleIsFresh(tap, 100));
    assert(LCTapSyncSampleIsFresh(tap, 100.75));
    assert(!LCTapSyncSampleIsFresh(tap, 100.751));
    assert(!LCTapSyncSampleIsFresh(tap, 99.999));
    assert(!LCTapSyncSampleIsFresh(tap, NAN));
    // Different content scales keep the same relative point, while reflowed/rotated layouts are rejected.
    assert(LCTapSyncCanMap(tap, 400, 800, 1));
    assert(LCTapSyncCanMap(tap, 100, 200, 1));
    assert(!LCTapSyncCanMap(tap, 400, 200, 1));
    assert(!LCTapSyncCanMap(tap, 200, 400, 2));
    assert(!LCTapSyncCanMap(tap, 200, 0, 1));
    assert(!LCTapSyncCanMap(tap, NAN, 400, 1));
    assert(!LCTapSyncCanMap(tap, INFINITY, 400, 1));
    assert(!LCTapSyncCanMap(tap, 210, 400, 1));
    tap.orientation = 3;
    assert(LCTapSyncCanMap(tap, 200, 400, 3));
    assert(!LCTapSyncCanMap(tap, 200, 400, 4));
    tap.x = 1;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.x = -0.01;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.x = NAN;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.x = 0;
    tap.y = INFINITY;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.y = 0;
    tap.duration = 0.351;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.duration = 0.1;
    tap.tapCount = 0;
    assert(!LCTapSyncSampleIsValid(tap));
    tap.tapCount = 2;
    assert(LCTapSyncSampleIsValid(tap));
    assert(LCTapSyncIsShortTap(0.35, 10));
    assert(!LCTapSyncIsShortTap(0.351, 0));
    assert(!LCTapSyncIsShortTap(0.1, 10.1));
    assert(!LCTapSyncIsShortTap(-0.1, 0));
    assert(!LCTapSyncIsShortTap(0.1, NAN));
    puts("Tap sync geometry tests passed (content scales, orientation, reflow, expiry and gesture boundaries).");
    return 0;
}
