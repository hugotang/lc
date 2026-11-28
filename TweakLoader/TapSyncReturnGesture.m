#import "TapSyncReturnGesture.h"

@interface LCTapSyncReturnGesture ()
@property(nonatomic) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic) LCTouchSyncStream touchStream;
@property(nonatomic) LCMultiTouchSyncStream frameStream;
@end

@implementation LCTapSyncReturnGesture
- (instancetype)initWithMode:(LCTapSyncMode)mode revision:(uint64_t)revision atTime:(NSTimeInterval)time {
    if ((mode != LCTapSyncModeTapsOnly && mode != LCTapSyncModeSingleFinger && mode != LCTapSyncModeTwoFingers) ||
        !revision || !isfinite(time) || time <= 0) return nil;
    if ((self = [super init])) {
        _mode = mode;
        _revision = revision;
        _beganAt = time;
        _queue = [NSMutableArray array];
    }
    return self;
}
- (NSArray<NSDictionary *> *)packets { return self.queue.copy; }
- (BOOL)hasActiveContacts {
    return self.mode == LCTapSyncModeSingleFinger ? self.touchStream.contact != 0 :
        self.mode == LCTapSyncModeTwoFingers && self.frameStream.count != 0;
}
- (BOOL)appendTap:(NSDictionary *)tap {
    LCTapSyncSample sample;
    if (self.mode != LCTapSyncModeTapsOnly || !LCTapSyncDecode(tap, &sample) || sample.timestamp < self.beganAt || self.queue.count >= 64) return NO;
    [self.queue addObject:@{@"tap": LCTapSyncEncode(sample)}];
    return YES;
}
- (BOOL)appendTouch:(NSDictionary *)touch {
    LCTouchSyncSample sample, previous;
    LCTouchSyncStream stream = self.touchStream;
    if (self.mode != LCTapSyncModeSingleFinger || !LCTouchSyncDecode(touch, &sample) || sample.timestamp < self.beganAt || !LCTouchSyncAdvance(&stream, sample)) return NO;
    BOOL coalesce = sample.phase == LCTouchSyncPhaseMoved && LCTouchSyncDecode(self.queue.lastObject[@"touch"], &previous) &&
        previous.phase == LCTouchSyncPhaseMoved && previous.contact == sample.contact;
    if (!coalesce && self.queue.count >= 64) return NO;
    NSDictionary *packet = @{@"touch": LCTouchSyncEncode(sample)};
    if (coalesce) self.queue[self.queue.count - 1] = packet;
    else [self.queue addObject:packet];
    self.touchStream = stream;
    return YES;
}
- (BOOL)appendFrame:(NSDictionary *)packet {
    LCMultiTouchSyncFrame frame, previous;
    LCMultiTouchSyncStream stream = self.frameStream;
    if (self.mode != LCTapSyncModeTwoFingers || !LCMultiTouchSyncDecode(packet, &frame) || frame.timestamp < self.beganAt || !LCMultiTouchSyncAdvance(&stream, frame)) return NO;
    BOOL coalesce = LCMultiTouchSyncDecode(self.queue.lastObject[@"frame"], &previous) && LCMultiTouchSyncCoalesce(previous, &frame);
    if (!coalesce && self.queue.count >= 64) return NO;
    NSDictionary *queued = @{@"frame": LCMultiTouchSyncEncode(frame)};
    if (coalesce) self.queue[self.queue.count - 1] = queued;
    else [self.queue addObject:queued];
    self.frameStream = stream;
    return YES;
}
- (BOOL)isFreshAtTime:(NSTimeInterval)time {
    // Recovery must not deliver a return gesture from a previous app screen.
    return isfinite(time) && self.beganAt > 0 && time >= self.beganAt && time - self.beganAt <= 0.75;
}
@end
