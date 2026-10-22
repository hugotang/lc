#import "TapSyncSession.h"

@interface LCTapSyncSession ()
@property(nonatomic) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic) uint64_t lastSequence;
@property(nonatomic) LCTouchSyncStream touchStream;
@end

@implementation LCTapSyncSession
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets {
    return [self initWithSource:source targets:targets mode:LCTapSyncModeTapsOnly];
}
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets mode:(LCTapSyncMode)mode {
    if (mode != LCTapSyncModeTapsOnly && mode != LCTapSyncModeSingleFinger) return nil;
    if (![source isKindOfClass:NSString.class] || source.length == 0 || source.length > 1024 ||
        ![targets isKindOfClass:NSArray.class] || targets.count == 0 || targets.count > 63) return nil;
    NSMutableSet *seen = [NSMutableSet setWithObject:source];
    for (id target in targets) {
        if (![target isKindOfClass:NSString.class] || [target length] == 0 || [target length] > 1024 ||
            [seen containsObject:target]) return nil;
        [seen addObject:target];
    }
    if ((self = [super init])) {
        _identifier = NSUUID.UUID.UUIDString;
        _source = source.copy;
        _targets = targets.copy;
        _mode = mode;
        _queue = [NSMutableArray array];
        _valid = YES;
    }
    return self;
}
- (NSUInteger)pendingCount { return self.queue.count; }
- (LCTapSyncResult)enqueue:(NSDictionary *)tap fromSource:(NSString *)source session:(NSString *)session
                 sequence:(uint64_t)sequence now:(NSTimeInterval)now {
    if (!self.valid || ![session isEqualToString:self.identifier] || ![source isEqualToString:self.source]) {
        return LCTapSyncResultStopped;
    }
    if (self.mode != LCTapSyncModeTapsOnly) return LCTapSyncResultInvalidGesture;
    // Reject duplicates and gaps instead of allowing a delayed/reordered click to affect a later screen.
    if (sequence == 0 || self.lastSequence == UINT64_MAX || sequence != self.lastSequence + 1) return LCTapSyncResultExpired;
    LCTapSyncSample sample;
    if (!LCTapSyncDecode(tap, &sample) || !LCTapSyncSampleIsFresh(sample, now)) return LCTapSyncResultExpired;
    if (self.queue.count >= 4) return LCTapSyncResultBusy;
    self.lastSequence = sequence;
    [self.queue addObject:@{@"tap": LCTapSyncEncode(sample), @"sequence": @(sequence)}];
    return LCTapSyncResultAccepted;
}
- (LCTapSyncResult)enqueueTouch:(NSDictionary *)touch fromSource:(NSString *)source session:(NSString *)session
                      sequence:(uint64_t)sequence now:(NSTimeInterval)now {
    if (!self.valid || ![session isEqualToString:self.identifier] || ![source isEqualToString:self.source]) {
        return LCTapSyncResultStopped;
    }
    if (self.mode != LCTapSyncModeSingleFinger) return LCTapSyncResultInvalidGesture;
    if (sequence == 0 || self.lastSequence == UINT64_MAX || sequence != self.lastSequence + 1) return LCTapSyncResultExpired;
    LCTouchSyncSample sample;
    if (!LCTouchSyncDecode(touch, &sample) || !LCTouchSyncSampleIsFresh(sample, now)) return LCTapSyncResultExpired;
    LCTouchSyncStream stream = self.touchStream;
    if (!LCTouchSyncAdvance(&stream, sample)) return LCTapSyncResultInvalidGesture;
    LCTouchSyncSample previous;
    BOOL coalesce = sample.phase == LCTouchSyncPhaseMoved &&
        LCTouchSyncDecode(self.queue.lastObject[@"touch"], &previous) &&
        previous.phase == LCTouchSyncPhaseMoved && previous.contact == sample.contact;
    if (!coalesce && self.queue.count >= 4) return LCTapSyncResultBusy;
    NSDictionary *packet = @{@"touch": LCTouchSyncEncode(sample), @"sequence": @(sequence)};
    // Only an unsent move can be replaced. Contact boundaries are never removed or reordered.
    if (coalesce) self.queue[self.queue.count - 1] = packet;
    else [self.queue addObject:packet];
    self.lastSequence = sequence;
    self.touchStream = stream;
    return LCTapSyncResultAccepted;
}
- (NSDictionary *)takeNextAtTime:(NSTimeInterval)now result:(LCTapSyncResult *)result {
    *result = self.valid ? LCTapSyncResultAccepted : LCTapSyncResultStopped;
    if (!self.valid || self.queue.count == 0) return nil;
    NSDictionary *next = self.queue.firstObject;
    LCTapSyncSample tap;
    LCTouchSyncSample touch;
    BOOL fresh = self.mode == LCTapSyncModeTapsOnly ?
        LCTapSyncDecode(next[@"tap"], &tap) && LCTapSyncSampleIsFresh(tap, now) :
        LCTouchSyncDecode(next[@"touch"], &touch) && LCTouchSyncSampleIsFresh(touch, now);
    if (!fresh) {
        *result = LCTapSyncResultExpired;
        [self invalidate];
        return nil;
    }
    [self.queue removeObjectAtIndex:0];
    return next;
}
- (void)invalidate {
    _valid = NO;
    self.touchStream = (LCTouchSyncStream){0};
    [self.queue removeAllObjects];
}
@end
