#import <Foundation/Foundation.h>
#include "TapSyncGeometry.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCTapSyncResult) {
    LCTapSyncResultAccepted = 0,
    LCTapSyncResultUnavailable,
    LCTapSyncResultUnsupported,
    LCTapSyncResultGeometryChanged,
    LCTapSyncResultBusy,
    LCTapSyncResultExpired,
    LCTapSyncResultStopped,
};

@protocol LCTapSyncGuestProtocol
- (void)prepareSession:(NSString *)session source:(BOOL)source reply:(void (^)(LCTapSyncResult))reply;
- (void)stopSession:(NSString *)session;
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply;
@end

@protocol LCTapSyncHostProtocol
- (void)readyWithVersion:(NSInteger)version canReplay:(BOOL)canReplay;
- (void)submitTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence;
- (void)interruptSession:(NSString *)session reason:(LCTapSyncResult)reason;
@end

static inline NSXPCInterface *LCTapSyncHostInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTapSyncHostProtocol)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(submitTap:session:sequence:) argumentIndex:0 ofReply:NO];
    return interface;
}

static inline NSXPCInterface *LCTapSyncGuestInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTapSyncGuestProtocol)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(replayTap:session:sequence:reply:) argumentIndex:0 ofReply:NO];
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

NS_ASSUME_NONNULL_END
