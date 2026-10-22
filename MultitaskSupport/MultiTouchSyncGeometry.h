#ifndef LC_MULTI_TOUCH_SYNC_GEOMETRY_H
#define LC_MULTI_TOUCH_SYNC_GEOMETRY_H

#include "TouchSyncGeometry.h"

enum { LCMultiTouchSyncMaximumContacts = 2, LCMultiTouchSyncMaximumFrameContacts = 4 };
typedef enum {
    LCMultiTouchSyncPhaseBegan = 0,
    LCMultiTouchSyncPhaseMoved,
    LCMultiTouchSyncPhaseEnded,
    LCMultiTouchSyncPhaseCancelled,
    LCMultiTouchSyncPhaseStationary,
} LCMultiTouchSyncPhase;

typedef struct {
    double x, y;
    uint32_t identifier;
    int tapCount;
    LCMultiTouchSyncPhase phase;
} LCMultiTouchSyncContact;

// Include every live contact and every release in one atomic UIKit frame. A frame may
// release two old fingers and begin two new ones, but at most two may remain down.
typedef struct {
    double width, height, timestamp;
    int orientation;
    unsigned count;
    LCMultiTouchSyncContact contacts[LCMultiTouchSyncMaximumFrameContacts];
} LCMultiTouchSyncFrame;

typedef struct {
    double width, height, timestamp;
    int orientation;
    uint32_t lastContact;
    unsigned count;
    bool cancelled;
    LCMultiTouchSyncContact contacts[LCMultiTouchSyncMaximumContacts];
} LCMultiTouchSyncStream;

static inline bool LCMultiTouchSyncIsDown(LCMultiTouchSyncContact contact) {
    return contact.phase != LCMultiTouchSyncPhaseEnded && contact.phase != LCMultiTouchSyncPhaseCancelled;
}

static inline bool LCMultiTouchSyncFrameIsValid(LCMultiTouchSyncFrame frame) {
    if (frame.count == 0 || frame.count > LCMultiTouchSyncMaximumFrameContacts) return false;
    unsigned down = 0, changed = 0;
    uint32_t previous = 0;
    for (unsigned i = 0; i < frame.count; i++) {
        LCMultiTouchSyncContact contact = frame.contacts[i];
        if (contact.phase < LCMultiTouchSyncPhaseBegan || contact.phase > LCMultiTouchSyncPhaseStationary ||
            contact.identifier <= previous) return false;
        previous = contact.identifier;
        LCTouchSyncSample sample = {contact.x, contact.y, frame.width, frame.height, frame.timestamp,
            contact.identifier, frame.orientation, contact.tapCount,
            contact.phase == LCMultiTouchSyncPhaseStationary ? LCTouchSyncPhaseMoved : (LCTouchSyncPhase)contact.phase};
        if (!LCTouchSyncSampleIsValid(sample)) return false;
        if (LCMultiTouchSyncIsDown(contact)) down++;
        if (contact.phase != LCMultiTouchSyncPhaseStationary) changed++;
    }
    return down <= LCMultiTouchSyncMaximumContacts && changed > 0;
}

static inline bool LCMultiTouchSyncFrameIsFresh(LCMultiTouchSyncFrame frame, double now) {
    return LCMultiTouchSyncFrameIsValid(frame) && isfinite(now) && now >= frame.timestamp && now - frame.timestamp <= 0.75;
}

static inline bool LCMultiTouchSyncCanMap(LCMultiTouchSyncFrame frame, double width, double height, int orientation) {
    LCTapSyncSample shape = {0, 0, frame.width, frame.height, frame.timestamp, 0, frame.orientation, 1};
    return LCMultiTouchSyncFrameIsValid(frame) && LCTapSyncCanMap(shape, width, height, orientation);
}

static inline bool LCMultiTouchSyncHasBoundary(LCMultiTouchSyncFrame frame) {
    for (unsigned i = 0; i < frame.count; i++) {
        if (frame.contacts[i].phase != LCMultiTouchSyncPhaseMoved &&
            frame.contacts[i].phase != LCMultiTouchSyncPhaseStationary) return true;
    }
    return false;
}

// Invalid input must not partly mutate the stream: both host and receiver use this.
static inline bool LCMultiTouchSyncAdvance(LCMultiTouchSyncStream *stream, LCMultiTouchSyncFrame frame) {
    if (!stream || !LCMultiTouchSyncFrameIsValid(frame) || frame.timestamp < stream->timestamp ||
        stream->count > LCMultiTouchSyncMaximumContacts) return false;
    if (stream->count && (stream->width != frame.width || stream->height != frame.height || stream->orientation != frame.orientation)) return false;
    LCMultiTouchSyncStream next = *stream;
    next.count = 0;
    if (!stream->count) next.cancelled = false;
    unsigned found = 0;
    for (unsigned i = 0; i < frame.count; i++) {
        LCMultiTouchSyncContact contact = frame.contacts[i];
        const LCMultiTouchSyncContact *previous = NULL;
        for (unsigned j = 0; j < stream->count; j++) {
            if (stream->contacts[j].identifier == contact.identifier) previous = &stream->contacts[j];
        }
        if (previous) {
            found++;
            if (contact.phase == LCMultiTouchSyncPhaseBegan || contact.tapCount != previous->tapCount) return false;
            if (contact.phase == LCMultiTouchSyncPhaseStationary && (contact.x != previous->x || contact.y != previous->y)) return false;
        } else {
            if (contact.phase != LCMultiTouchSyncPhaseBegan || contact.identifier <= next.lastContact) return false;
            next.lastContact = contact.identifier;
        }
        if (contact.phase == LCMultiTouchSyncPhaseCancelled) next.cancelled = true;
        if (LCMultiTouchSyncIsDown(contact)) next.contacts[next.count++] = contact;
    }
    // Silently losing a finger would leave the receiving app pressed indefinitely.
    if (found != stream->count) return false;
    next.width = frame.width;
    next.height = frame.height;
    next.orientation = frame.orientation;
    next.timestamp = frame.timestamp;
    *stream = next;
    return true;
}

// Only replace consecutive motion frames with the same contacts. Preserve a move
// on finger A even if A is stationary by the time finger B's newer move arrives.
static inline bool LCMultiTouchSyncCoalesce(LCMultiTouchSyncFrame earlier, LCMultiTouchSyncFrame *later) {
    if (!later || !LCMultiTouchSyncFrameIsValid(earlier) || !LCMultiTouchSyncFrameIsValid(*later) ||
        LCMultiTouchSyncHasBoundary(earlier) || LCMultiTouchSyncHasBoundary(*later) ||
        earlier.count != later->count || earlier.timestamp > later->timestamp ||
        earlier.width != later->width || earlier.height != later->height || earlier.orientation != later->orientation) return false;
    for (unsigned i = 0; i < earlier.count; i++) {
        if (earlier.contacts[i].identifier != later->contacts[i].identifier ||
            earlier.contacts[i].tapCount != later->contacts[i].tapCount) return false;
    }
    for (unsigned i = 0; i < earlier.count; i++) {
        if (earlier.contacts[i].phase == LCMultiTouchSyncPhaseMoved) later->contacts[i].phase = LCMultiTouchSyncPhaseMoved;
    }
    return true;
}

#endif
