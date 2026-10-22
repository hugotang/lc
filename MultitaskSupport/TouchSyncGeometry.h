#ifndef LC_TOUCH_SYNC_GEOMETRY_H
#define LC_TOUCH_SYNC_GEOMETRY_H

#include "TapSyncGeometry.h"
#include <stdint.h>

typedef enum {
    LCTouchSyncPhaseBegan = 0,
    LCTouchSyncPhaseMoved,
    LCTouchSyncPhaseEnded,
    LCTouchSyncPhaseCancelled,
} LCTouchSyncPhase;

typedef struct {
    double x, y, width, height, timestamp;
    uint32_t contact;
    int orientation, tapCount;
    LCTouchSyncPhase phase;
} LCTouchSyncSample;

// One contact stays down across packets, including holds with no movement packets.
typedef struct {
    uint32_t contact, lastContact;
    double timestamp, width, height;
    int orientation, tapCount;
} LCTouchSyncStream;

static inline bool LCTouchSyncSampleIsValid(LCTouchSyncSample sample) {
    if (sample.phase < LCTouchSyncPhaseBegan || sample.phase > LCTouchSyncPhaseCancelled || sample.contact == 0 ||
        !isfinite(sample.x) || !isfinite(sample.y) || !isfinite(sample.width) || !isfinite(sample.height) ||
        sample.width < 1 || sample.height < 1 || sample.width > 32768 || sample.height > 32768 ||
        !isfinite(sample.timestamp) || sample.timestamp <= 0 || sample.orientation < 1 || sample.orientation > 4 ||
        sample.tapCount < 1 || sample.tapCount > 10) return false;
    if (sample.phase == LCTouchSyncPhaseBegan) {
        return sample.x >= 0 && sample.x < 1 && sample.y >= 0 && sample.y < 1;
    }
    // UIKit tracks a finger outside its original view. Do not clamp it onto a button at the edge.
    return sample.x >= -1 && sample.x <= 2 && sample.y >= -1 && sample.y <= 2;
}

static inline bool LCTouchSyncSampleIsFresh(LCTouchSyncSample sample, double now) {
    return LCTouchSyncSampleIsValid(sample) && isfinite(now) && now >= sample.timestamp && now - sample.timestamp <= 0.75;
}

static inline bool LCTouchSyncCanMap(LCTouchSyncSample sample, double width, double height, int orientation) {
    LCTapSyncSample shape = {0, 0, sample.width, sample.height, sample.timestamp, 0, sample.orientation, sample.tapCount};
    return LCTouchSyncSampleIsValid(sample) && LCTapSyncCanMap(shape, width, height, orientation);
}

// Invalid packets leave the state unchanged. Used at both the host and the receiving guest.
static inline bool LCTouchSyncAdvance(LCTouchSyncStream *stream, LCTouchSyncSample sample) {
    if (!stream || !LCTouchSyncSampleIsValid(sample) || sample.timestamp < stream->timestamp) return false;
    if (sample.phase == LCTouchSyncPhaseBegan) {
        if (stream->contact || sample.contact <= stream->lastContact) return false;
        stream->contact = sample.contact;
        stream->lastContact = sample.contact;
        stream->width = sample.width;
        stream->height = sample.height;
        stream->orientation = sample.orientation;
        stream->tapCount = sample.tapCount;
    } else {
        if (stream->contact != sample.contact || stream->width != sample.width || stream->height != sample.height ||
            stream->orientation != sample.orientation || stream->tapCount != sample.tapCount) return false;
        if (sample.phase == LCTouchSyncPhaseEnded || sample.phase == LCTouchSyncPhaseCancelled) stream->contact = 0;
    }
    stream->timestamp = sample.timestamp;
    return true;
}

#endif
