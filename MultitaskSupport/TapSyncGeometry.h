#ifndef LC_TAP_SYNC_GEOMETRY_H
#define LC_TAP_SYNC_GEOMETRY_H

#include <stdbool.h>
#include <math.h>

// Coordinates belong to the guest window, so host bars and reserved margins never enter the mapping.
typedef struct {
    double x, y, width, height, timestamp, duration;
    int orientation, tapCount;
} LCTapSyncSample;

static inline bool LCTapSyncSampleIsValid(LCTapSyncSample tap) {
    return isfinite(tap.x) && isfinite(tap.y) && tap.x >= 0 && tap.x < 1 && tap.y >= 0 && tap.y < 1 &&
        isfinite(tap.width) && isfinite(tap.height) && tap.width >= 1 && tap.height >= 1 &&
        tap.width <= 32768 && tap.height <= 32768 && isfinite(tap.timestamp) && tap.timestamp > 0 &&
        isfinite(tap.duration) && tap.duration >= 0 && tap.duration <= 0.35 &&
        tap.orientation >= 1 && tap.orientation <= 4 && tap.tapCount >= 1 && tap.tapCount <= 10;
}

static inline bool LCTapSyncSampleIsFresh(LCTapSyncSample tap, double now) {
    return LCTapSyncSampleIsValid(tap) && isfinite(now) && now >= tap.timestamp && now - tap.timestamp <= 0.75;
}

static inline bool LCTapSyncCanMap(LCTapSyncSample tap, double width, double height, int orientation) {
    if (!LCTapSyncSampleIsValid(tap) || !isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
        width > 32768 || height > 32768 || orientation != tap.orientation) return false;
    // A different aspect ratio can reflow controls. Ask the user to align windows instead of guessing.
    return fabs((width / height) / (tap.width / tap.height) - 1) <= 0.025;
}

static inline bool LCTapSyncIsShortTap(double elapsed, double maximumTravel) {
    return isfinite(elapsed) && elapsed >= 0 && elapsed <= 0.35 &&
        isfinite(maximumTravel) && maximumTravel >= 0 && maximumTravel <= 10;
}

#endif
