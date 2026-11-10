#ifndef LC_TAP_SYNC_DIAGNOSTICS_H
#define LC_TAP_SYNC_DIAGNOSTICS_H
#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Built only when input is rejected. Never retain the packet, coordinates or account identifiers.
static inline NSString *LCTapSyncDiagnosticMode(LCTapSyncMode mode) {
    return mode == LCTapSyncModeSingleFinger ? @"singleFinger" : mode == LCTapSyncModeTwoFingers ? @"twoFingers" : @"tapsOnly";
}

static inline NSDictionary *LCTapSyncInputFailure(id _Nullable packet, LCTapSyncMode mode, uint64_t sequence,
                                                 uint64_t previousSequence, NSTimeInterval now, NSString *stage) {
    LCTapSyncSample tap = {0};
    LCTouchSyncSample touch = {0};
    LCMultiTouchSyncFrame frame = {0};
    BOOL decoded = mode == LCTapSyncModeTapsOnly ? LCTapSyncDecode(packet, &tap) :
        mode == LCTapSyncModeSingleFinger ? LCTouchSyncDecode(packet, &touch) : LCMultiTouchSyncDecode(packet, &frame);
    NSTimeInterval timestamp = mode == LCTapSyncModeTapsOnly ? tap.timestamp :
        mode == LCTapSyncModeSingleFinger ? touch.timestamp : frame.timestamp;
    BOOL checksSequence = [stage isEqualToString:@"hostReceive"] || [stage isEqualToString:@"guestReceive"];
    NSString *reason;
    if (checksSequence && previousSequence == UINT64_MAX) reason = @"sequenceExhausted";
    else if (checksSequence && (!sequence || sequence != previousSequence + 1)) reason = @"sequenceMismatch";
    else if (!isfinite(now) || now <= 0) reason = @"invalidClock";
    else if (!decoded) reason = @"invalidPacket";
    else if (timestamp > now) reason = @"timestampAhead";
    else if (now - timestamp > 0.75) reason = @"inputTooOld";
    else reason = @"unknown";
    NSMutableDictionary *record = [@{@"reason": reason, @"stage": stage, @"mode": LCTapSyncDiagnosticMode(mode),
        @"receivedSequence": @(sequence), @"sequenceCheck": checksSequence ? @"checked" :
            [stage isEqualToString:@"hostReturnCapture"] ? @"captureOrder" : @"alreadyAccepted", @"ageLimitMs": @750} mutableCopy];
    if (checksSequence) {
        record[@"previousSequence"] = @(previousSequence);
        if (previousSequence != UINT64_MAX) record[@"expectedSequence"] = @(previousSequence + 1);
    }
    if (isfinite(now) && now > 0) record[@"observedAtUptime"] = @(now);
    double age = (now - timestamp) * 1000;
    if (decoded && isfinite(age)) record[@"inputAgeMs"] = @(age);
    if (decoded && mode == LCTapSyncModeSingleFinger) record[@"phase"] = @(touch.phase);
    return record.copy;
}

// Restrict replies to diagnostic scalars before copying them outside the process.
static inline NSDictionary * _Nullable LCTapSyncSanitizedInputFailure(id _Nullable value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"reason", @"stage", @"mode"]) {
        id item = value[key];
        if (![item isKindOfClass:NSString.class] || ![item length] || [item length] > 64) return nil;
        record[key] = item;
    }
    id sequenceCheck = value[@"sequenceCheck"];
    if ([sequenceCheck isKindOfClass:NSString.class] && [sequenceCheck length] <= 32) record[@"sequenceCheck"] = sequenceCheck;
    for (NSString *key in @[@"receivedSequence", @"previousSequence", @"expectedSequence", @"ageLimitMs", @"observedAtUptime", @"inputAgeMs", @"phase"]) {
        id item = value[key];
        if ([item isKindOfClass:NSNumber.class] && isfinite([item doubleValue])) record[key] = item;
    }
    return record.copy;
}

NS_ASSUME_NONNULL_END
#endif
