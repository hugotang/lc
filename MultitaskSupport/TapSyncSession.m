#import "TapSyncSession.h"
#import "TapSyncDiagnostics.h"

@interface LCTapSyncPreparation ()
@property(nonatomic) NSMutableOrderedSet<NSString *> *pending;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *failedResults;
@end

@implementation LCTapSyncPreparation
- (instancetype)initWithContainers:(NSArray<NSString *> *)containers {
    if ((self = [super init])) {
        _pending = [NSMutableOrderedSet orderedSetWithArray:containers];
        _failedResults = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSArray<NSString *> *)pendingContainers { return self.pending.array; }
- (NSDictionary<NSString *, NSNumber *> *)failures { return self.failedResults.copy; }
- (BOOL)recordResult:(LCTapSyncResult)result forContainer:(NSString *)container {
    if (![self.pending containsObject:container]) return NO;
    [self.pending removeObject:container];
    if (result != LCTapSyncResultAccepted) self.failedResults[container] = @(result);
    return YES;
}
- (NSDictionary<NSString *, NSNumber *> *)failuresIncludingTimeouts {
    NSMutableDictionary *failures = self.failedResults.mutableCopy;
    for (NSString *container in self.pending) failures[container] = @(LCTapSyncResultPreparationTimedOut);
    return failures.copy;
}
@end

@interface LCTapSyncSession ()
@property(nonatomic) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic) NSMutableArray<NSDictionary *> *returnQueue;
@property(nonatomic) BOOL receivedSourceReturn;
@property(nonatomic) uint64_t lastSequence;
@property(nonatomic) LCTouchSyncStream touchStream;
@property(nonatomic) LCMultiTouchSyncStream multiTouchStream;
@property(nonatomic, copy, readwrite) NSDictionary *lastInputFailure;
@end

@implementation LCTapSyncSession
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets {
    return [self initWithSource:source targets:targets mode:LCTapSyncModeTapsOnly];
}
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets mode:(LCTapSyncMode)mode {
    if (mode != LCTapSyncModeTapsOnly && mode != LCTapSyncModeSingleFinger && mode != LCTapSyncModeTwoFingers) return nil;
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
- (NSUInteger)pendingCount { return self.returnQueue.count + self.queue.count; }
- (LCTapSyncResult)enqueueSourceReturn:(NSArray<NSDictionary *> *)packets fromSource:(NSString *)source
                              session:(NSString *)session now:(NSTimeInterval)now {
    if (!self.valid || ![session isEqualToString:self.identifier] || ![source isEqualToString:self.source]) return LCTapSyncResultStopped;
    if (self.receivedSourceReturn || self.lastSequence || self.pendingCount) return LCTapSyncResultInvalidGesture;
    if (!isfinite(now) || now <= 0) return LCTapSyncResultExpired;
    if (![packets isKindOfClass:NSArray.class] || packets.count > 64) return LCTapSyncResultInvalidGesture;
    NSMutableArray *validated = [NSMutableArray arrayWithCapacity:packets.count];
    LCTouchSyncStream touchStream = {0};
    LCMultiTouchSyncStream frameStream = {0};
    uint64_t sequence = 0;
    for (id packet in packets) {
        if (![packet isKindOfClass:NSDictionary.class] || [packet count] != 1) return LCTapSyncResultInvalidGesture;
        LCTapSyncSample tap;
        LCTouchSyncSample touch;
        LCMultiTouchSyncFrame frame;
        NSDictionary *queued;
        if (self.mode == LCTapSyncModeTapsOnly) {
            if (!LCTapSyncDecode(packet[@"tap"], &tap)) return LCTapSyncResultInvalidGesture;
            if (!LCTapSyncSampleIsFresh(tap, now)) {
                self.lastInputFailure = LCTapSyncInputFailure(packet[@"tap"], self.mode, sequence + 1, sequence, now, @"hostReturnCapture");
                return LCTapSyncResultExpired;
            }
            queued = @{@"tap": LCTapSyncEncode(tap), @"sequence": @(++sequence)};
        } else if (self.mode == LCTapSyncModeSingleFinger) {
            if (!LCTouchSyncDecode(packet[@"touch"], &touch) || !LCTouchSyncAdvance(&touchStream, touch)) return LCTapSyncResultInvalidGesture;
            if (!LCTouchSyncSampleIsFresh(touch, now)) {
                self.lastInputFailure = LCTapSyncInputFailure(packet[@"touch"], self.mode, sequence + 1, sequence, now, @"hostReturnCapture");
                return LCTapSyncResultExpired;
            }
            queued = @{@"touch": LCTouchSyncEncode(touch), @"sequence": @(++sequence)};
        } else {
            if (!LCMultiTouchSyncDecode(packet[@"frame"], &frame) || !LCMultiTouchSyncAdvance(&frameStream, frame)) return LCTapSyncResultInvalidGesture;
            if (!LCMultiTouchSyncFrameIsFresh(frame, now)) {
                self.lastInputFailure = LCTapSyncInputFailure(packet[@"frame"], self.mode, sequence + 1, sequence, now, @"hostReturnCapture");
                return LCTapSyncResultExpired;
            }
            queued = @{@"frame": LCMultiTouchSyncEncode(frame), @"sequence": @(++sequence),
                       @"completed": @(frameStream.count == 0 && !frameStream.cancelled)};
        }
        [validated addObject:queued];
    }
    self.returnQueue = validated;
    self.touchStream = touchStream;
    self.multiTouchStream = frameStream;
    self.lastSequence = sequence;
    self.receivedSourceReturn = YES;
    return LCTapSyncResultAccepted;
}
- (LCTapSyncResult)enqueue:(NSDictionary *)tap fromSource:(NSString *)source session:(NSString *)session
                 sequence:(uint64_t)sequence now:(NSTimeInterval)now {
    if (!self.valid || ![session isEqualToString:self.identifier] || ![source isEqualToString:self.source]) {
        return LCTapSyncResultStopped;
    }
    if (self.mode != LCTapSyncModeTapsOnly) return LCTapSyncResultInvalidGesture;
    // Reject duplicates and gaps instead of allowing a delayed/reordered click to affect a later screen.
    if (sequence == 0 || self.lastSequence == UINT64_MAX || sequence != self.lastSequence + 1) {
        self.lastInputFailure = LCTapSyncInputFailure(tap, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
    LCTapSyncSample sample;
    if (!LCTapSyncDecode(tap, &sample) || !LCTapSyncSampleIsFresh(sample, now)) {
        self.lastInputFailure = LCTapSyncInputFailure(tap, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
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
    if (sequence == 0 || self.lastSequence == UINT64_MAX || sequence != self.lastSequence + 1) {
        self.lastInputFailure = LCTapSyncInputFailure(touch, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
    LCTouchSyncSample sample;
    if (!LCTouchSyncDecode(touch, &sample) || !LCTouchSyncSampleIsFresh(sample, now)) {
        self.lastInputFailure = LCTapSyncInputFailure(touch, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
    LCTouchSyncStream stream = self.touchStream;
    if (!LCTouchSyncAdvance(&stream, sample)) return LCTapSyncResultInvalidGesture;
    LCTouchSyncSample previous;
    BOOL coalesce = sample.phase == LCTouchSyncPhaseMoved &&
        LCTouchSyncDecode(self.queue.lastObject[@"touch"], &previous) &&
        previous.phase == LCTouchSyncPhaseMoved && previous.contact == sample.contact;
    if (!coalesce && self.queue.count >= 4) return LCTapSyncResultBusy;
    NSDictionary *packet = @{@"touch": LCTouchSyncEncode(sample), @"sequence": @(sequence)};
    // Only an unsent move can be replaced. Contact boundaries are never removed or reordered.
    if (coalesce) { self.queue[self.queue.count - 1] = packet; _coalescedMoveCount++; }
    else [self.queue addObject:packet];
    self.lastSequence = sequence;
    self.touchStream = stream;
    return LCTapSyncResultAccepted;
}
- (LCTapSyncResult)enqueueTouchFrame:(NSDictionary *)packet fromSource:(NSString *)source session:(NSString *)session
                           sequence:(uint64_t)sequence now:(NSTimeInterval)now {
    if (!self.valid || ![session isEqualToString:self.identifier] || ![source isEqualToString:self.source]) return LCTapSyncResultStopped;
    if (self.mode != LCTapSyncModeTwoFingers) return LCTapSyncResultInvalidGesture;
    if (sequence == 0 || self.lastSequence == UINT64_MAX || sequence != self.lastSequence + 1) {
        self.lastInputFailure = LCTapSyncInputFailure(packet, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
    LCMultiTouchSyncFrame frame;
    if (!LCMultiTouchSyncDecode(packet, &frame) || !LCMultiTouchSyncFrameIsFresh(frame, now)) {
        self.lastInputFailure = LCTapSyncInputFailure(packet, self.mode, sequence, self.lastSequence, now, @"hostReceive");
        return LCTapSyncResultExpired;
    }
    LCMultiTouchSyncStream stream = self.multiTouchStream;
    if (!LCMultiTouchSyncAdvance(&stream, frame)) return LCTapSyncResultInvalidGesture;
    LCMultiTouchSyncFrame previous;
    BOOL coalesce = LCMultiTouchSyncDecode(self.queue.lastObject[@"frame"], &previous) && LCMultiTouchSyncCoalesce(previous, &frame);
    if (!coalesce && self.queue.count >= 4) return LCTapSyncResultBusy;
    NSDictionary *queued = @{@"frame": LCMultiTouchSyncEncode(frame), @"sequence": @(sequence),
        @"completed": @(stream.count == 0 && !stream.cancelled)};
    if (coalesce) { self.queue[self.queue.count - 1] = queued; _coalescedMoveCount++; }
    else [self.queue addObject:queued];
    self.lastSequence = sequence;
    self.multiTouchStream = stream;
    return LCTapSyncResultAccepted;
}
- (NSDictionary *)takeNextAtTime:(NSTimeInterval)now result:(LCTapSyncResult *)result {
    *result = self.valid ? LCTapSyncResultAccepted : LCTapSyncResultStopped;
    if (!self.valid || self.pendingCount == 0) return nil;
    NSMutableArray *queue = self.returnQueue.count ? self.returnQueue : self.queue;
    NSDictionary *next = queue.firstObject;
    LCTapSyncSample tap;
    LCTouchSyncSample touch;
    LCMultiTouchSyncFrame frame;
    BOOL fresh = self.mode == LCTapSyncModeTapsOnly ?
        LCTapSyncDecode(next[@"tap"], &tap) && LCTapSyncSampleIsFresh(tap, now) : self.mode == LCTapSyncModeSingleFinger ?
        LCTouchSyncDecode(next[@"touch"], &touch) && LCTouchSyncSampleIsFresh(touch, now) :
        LCMultiTouchSyncDecode(next[@"frame"], &frame) && LCMultiTouchSyncFrameIsFresh(frame, now);
    if (!fresh) {
        uint64_t sequence = [next[@"sequence"] unsignedLongLongValue];
        self.lastInputFailure = LCTapSyncInputFailure(next[@"tap"] ?: next[@"touch"] ?: next[@"frame"],
            self.mode, sequence, sequence ? sequence - 1 : 0, now, @"hostQueue");
        *result = LCTapSyncResultExpired;
        [self invalidate];
        return nil;
    }
    [queue removeObjectAtIndex:0];
    return next;
}
- (void)invalidate {
    _valid = NO;
    self.touchStream = (LCTouchSyncStream){0};
    self.multiTouchStream = (LCMultiTouchSyncStream){0};
    [self.queue removeAllObjects];
    [self.returnQueue removeAllObjects];
}
@end
