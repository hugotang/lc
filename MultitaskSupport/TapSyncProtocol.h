#import <Foundation/Foundation.h>
#include "TapSyncGeometry.h"
#include "TouchSyncGeometry.h"
#include "MultiTouchSyncGeometry.h"

NS_ASSUME_NONNULL_BEGIN

enum { LCTapSyncProtocolVersion = 4 };

typedef NS_ENUM(NSInteger, LCTapSyncMode) {
    LCTapSyncModeTapsOnly = 0,
    LCTapSyncModeSingleFinger,
    LCTapSyncModeTwoFingers,
};

typedef NS_ENUM(NSInteger, LCTapSyncResult) {
    LCTapSyncResultAccepted = 0,
    LCTapSyncResultUnavailable,
    LCTapSyncResultUnsupported,
    LCTapSyncResultGeometryChanged,
    LCTapSyncResultBusy,
    LCTapSyncResultExpired,
    LCTapSyncResultStopped,
    LCTapSyncResultInvalidGesture,
    LCTapSyncResultMultipleTouches,
    LCTapSyncResultTooManyTouches,
    LCTapSyncResultSceneInactive,
    LCTapSyncResultWindowCovered,
    LCTapSyncResultWindowNotReady,
    LCTapSyncResultKeyboardVisible,
    LCTapSyncResultPhysicalTouch,
    LCTapSyncResultPreparationTimedOut,
    LCTapSyncResultSuspended,
};

@protocol LCTapSyncGuestProtocol
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode resumeOnSource:(BOOL)resumeOnSource
                 reply:(void (^)(LCTapSyncResult))reply;
- (void)suspendSession:(NSString *)session reply:(void (^)(LCTapSyncResult, BOOL, uint64_t))reply;
- (void)stopSession:(NSString *)session;
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply;
- (void)replayTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence
             reply:(void (^)(LCTapSyncResult))reply;
- (void)replayTouchFrame:(NSDictionary *)frame session:(NSString *)session sequence:(uint64_t)sequence
                  reply:(void (^)(LCTapSyncResult))reply;
- (void)samplePerformanceWithReply:(void (^)(NSDictionary *))reply;
@end

@protocol LCTapSyncHostProtocol
- (void)readyWithVersion:(NSInteger)version canReplay:(BOOL)canReplay;
- (void)submitTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence;
- (void)submitTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence;
- (void)submitTouchFrame:(NSDictionary *)frame session:(NSString *)session sequence:(uint64_t)sequence;
- (void)interruptSession:(NSString *)session reason:(LCTapSyncResult)reason;
- (void)physicalInputChanged:(BOOL)touching began:(BOOL)began session:(NSString *)session revision:(uint64_t)revision timestamp:(NSTimeInterval)timestamp;
@end

static inline NSXPCInterface *LCTapSyncHostInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTapSyncHostProtocol)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(submitTap:session:sequence:) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(submitTouch:session:sequence:) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(submitTouchFrame:session:sequence:) argumentIndex:0 ofReply:NO];
    return interface;
}

static inline NSXPCInterface *LCTapSyncGuestInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTapSyncGuestProtocol)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(replayTap:session:sequence:reply:) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(replayTouch:session:sequence:reply:) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(replayTouchFrame:session:sequence:reply:) argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(samplePerformanceWithReply:) argumentIndex:0 ofReply:YES];
    return interface;
}

static inline NSDictionary *LCTapSyncEncode(LCTapSyncSample tap) {
    return @{@"x": @(tap.x), @"y": @(tap.y), @"width": @(tap.width), @"height": @(tap.height),
             @"timestamp": @(tap.timestamp), @"duration": @(tap.duration), @"orientation": @(tap.orientation),
             @"tapCount": @(tap.tapCount)};
}

static inline BOOL LCTapSyncDecode(id value, LCTapSyncSample * _Nullable sample) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 8) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height", @"timestamp", @"duration", @"orientation", @"tapCount"]) {
        if (![value[key] isKindOfClass:NSNumber.class]) return NO;
    }
    double orientation = [value[@"orientation"] doubleValue];
    if (!isfinite(orientation) || orientation < 1 || orientation > 4 || floor(orientation) != orientation) return NO;
    double tapCount = [value[@"tapCount"] doubleValue];
    if (!isfinite(tapCount) || tapCount < 1 || tapCount > 10 || floor(tapCount) != tapCount) return NO;
    LCTapSyncSample tap = {[value[@"x"] doubleValue], [value[@"y"] doubleValue],
        [value[@"width"] doubleValue], [value[@"height"] doubleValue], [value[@"timestamp"] doubleValue],
        [value[@"duration"] doubleValue], (int)orientation, (int)tapCount};
    if (!LCTapSyncSampleIsValid(tap)) return NO;
    if (sample) *sample = tap;
    return YES;
}

static inline NSDictionary *LCTouchSyncEncode(LCTouchSyncSample touch) {
    return @{@"x": @(touch.x), @"y": @(touch.y), @"width": @(touch.width), @"height": @(touch.height),
             @"timestamp": @(touch.timestamp), @"contact": @(touch.contact), @"orientation": @(touch.orientation),
             @"tapCount": @(touch.tapCount), @"phase": @(touch.phase)};
}

static inline BOOL LCTouchSyncDecode(id value, LCTouchSyncSample * _Nullable sample) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 9) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height", @"timestamp", @"contact", @"orientation", @"tapCount", @"phase"]) {
        if (![value[key] isKindOfClass:NSNumber.class]) return NO;
    }
    double contact = [value[@"contact"] doubleValue], phase = [value[@"phase"] doubleValue];
    double orientation = [value[@"orientation"] doubleValue], tapCount = [value[@"tapCount"] doubleValue];
    if (!isfinite(contact) || contact < 1 || contact > UINT32_MAX || floor(contact) != contact ||
        !isfinite(phase) || phase < LCTouchSyncPhaseBegan || phase > LCTouchSyncPhaseCancelled || floor(phase) != phase ||
        !isfinite(orientation) || orientation < 1 || orientation > 4 || floor(orientation) != orientation ||
        !isfinite(tapCount) || tapCount < 1 || tapCount > 10 || floor(tapCount) != tapCount) return NO;
    LCTouchSyncSample touch = {[value[@"x"] doubleValue], [value[@"y"] doubleValue],
        [value[@"width"] doubleValue], [value[@"height"] doubleValue], [value[@"timestamp"] doubleValue],
        (uint32_t)contact, (int)orientation, (int)tapCount, (LCTouchSyncPhase)phase};
    if (!LCTouchSyncSampleIsValid(touch)) return NO;
    if (sample) *sample = touch;
    return YES;
}

static inline NSDictionary *LCMultiTouchSyncEncode(LCMultiTouchSyncFrame frame) {
    NSMutableArray *contacts = [NSMutableArray arrayWithCapacity:frame.count];
    for (unsigned i = 0; i < frame.count; i++) {
        LCMultiTouchSyncContact contact = frame.contacts[i];
        [contacts addObject:@{@"x": @(contact.x), @"y": @(contact.y), @"contact": @(contact.identifier),
            @"tapCount": @(contact.tapCount), @"phase": @(contact.phase)}];
    }
    return @{@"width": @(frame.width), @"height": @(frame.height), @"timestamp": @(frame.timestamp),
        @"orientation": @(frame.orientation), @"contacts": contacts.copy};
}

static inline BOOL LCMultiTouchSyncDecode(id value, LCMultiTouchSyncFrame * _Nullable output) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 5) return NO;
    for (NSString *key in @[@"width", @"height", @"timestamp", @"orientation"]) {
        if (![value[key] isKindOfClass:NSNumber.class]) return NO;
    }
    double orientation = [value[@"orientation"] doubleValue];
    NSArray *contacts = value[@"contacts"];
    if (!isfinite(orientation) || orientation < 1 || orientation > 4 || floor(orientation) != orientation ||
        ![contacts isKindOfClass:NSArray.class] || contacts.count == 0 || contacts.count > LCMultiTouchSyncMaximumFrameContacts) return NO;
    LCMultiTouchSyncFrame frame = {.width = [value[@"width"] doubleValue], .height = [value[@"height"] doubleValue],
        .timestamp = [value[@"timestamp"] doubleValue], .orientation = (int)orientation, .count = (unsigned)contacts.count};
    for (unsigned i = 0; i < frame.count; i++) {
        id contact = contacts[i];
        if (![contact isKindOfClass:NSDictionary.class] || [contact count] != 5) return NO;
        for (NSString *key in @[@"x", @"y", @"contact", @"tapCount", @"phase"]) {
            if (![contact[key] isKindOfClass:NSNumber.class]) return NO;
        }
        double identifier = [contact[@"contact"] doubleValue], phase = [contact[@"phase"] doubleValue];
        double tapCount = [contact[@"tapCount"] doubleValue];
        if (!isfinite(identifier) || identifier < 1 || identifier > UINT32_MAX || floor(identifier) != identifier ||
            !isfinite(phase) || phase < LCMultiTouchSyncPhaseBegan || phase > LCMultiTouchSyncPhaseStationary || floor(phase) != phase ||
            !isfinite(tapCount) || tapCount < 1 || tapCount > 10 || floor(tapCount) != tapCount) return NO;
        frame.contacts[i] = (LCMultiTouchSyncContact){[contact[@"x"] doubleValue], [contact[@"y"] doubleValue],
            (uint32_t)identifier, (int)tapCount, (LCMultiTouchSyncPhase)phase};
    }
    if (!LCMultiTouchSyncFrameIsValid(frame)) return NO;
    if (output) *output = frame;
    return YES;
}

NS_ASSUME_NONNULL_END
