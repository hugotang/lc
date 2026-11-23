#import "TapSyncRecovery.h"
#include <math.h>

@interface LCTapSyncRecovery ()
@property(nonatomic, copy) NSString *source;
@property(nonatomic) NSSet<NSString *> *participants;
@property(nonatomic) NSMutableOrderedSet<NSString *> *pending;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *revisions;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *inputRevisions;
@property(nonatomic) NSMutableSet<NSString *> *touching;
@property(nonatomic) NSTimeInterval sourceReturnedAt, lastFollowerBeganAt;
@property(nonatomic, copy) NSArray *layout;
@property(nonatomic) NSTimeInterval layoutSince;
@end

@implementation LCTapSyncRecovery
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets reason:(LCTapSyncRecoveryReason)reason afterTime:(NSTimeInterval)time {
    if ((self = [super init])) {
        _source = source.copy;
        _reason = reason;
        _lastFollowerBeganAt = time;
        _valid = YES;
        NSArray *members = [@[source] arrayByAddingObjectsFromArray:targets];
        _participants = [NSSet setWithArray:members];
        _pending = [NSMutableOrderedSet orderedSetWithArray:members];
        _revisions = [NSMutableDictionary dictionary];
        _inputRevisions = [NSMutableDictionary dictionary];
        _touching = [NSMutableSet set];
    }
    return self;
}
- (NSArray<NSString *> *)pendingContainers { return self.pending.array; }
- (BOOL)canResume {
    return self.valid && self.pending.count == 0 && self.touching.count == 0 &&
        (self.reason == LCTapSyncRecoveryRotation || self.sourceReturnedAt > self.lastFollowerBeganAt);
}
- (BOOL)sourceHasReturned { return self.valid && self.sourceReturnedAt > self.lastFollowerBeganAt; }
- (BOOL)canResumeWithSourceGesture {
    return self.valid && self.pending.count == 0 && self.sourceHasReturned &&
        (self.touching.count == 0 || (self.touching.count == 1 && [self.touching containsObject:self.source]));
}
- (BOOL)recordInputForContainer:(NSString *)container revision:(uint64_t)revision touching:(BOOL)touching began:(BOOL)began atTime:(NSTimeInterval)time {
    if (!self.valid || ![self.participants containsObject:container] || !isfinite(time) || time < 0 || (began && !touching)) return NO;
    NSNumber *previous = self.inputRevisions[container];
    if (previous && revision <= previous.unsignedLongLongValue) return NO;
    self.inputRevisions[container] = @(revision);
    [self updatePhysicalStateForContainer:container revision:revision touching:touching];
    // An RPC snapshot can arrive before its earlier input notifications. Preserve
    // their return gesture without rolling the physical state back to finger-down.
    if (began) {
        // UITouch timestamps share the device's uptime clock across processes.
        // An earlier follower begin arriving late cannot undo a newer source return.
        if ([container isEqualToString:self.source]) self.sourceReturnedAt = MAX(self.sourceReturnedAt, time);
        else self.lastFollowerBeganAt = MAX(self.lastFollowerBeganAt, time);
    }
    if (!self.canResume) self.layout = nil;
    return YES;
}
- (void)updatePhysicalStateForContainer:(NSString *)container revision:(uint64_t)revision touching:(BOOL)touching {
    NSNumber *previous = self.revisions[container];
    if (previous && revision <= previous.unsignedLongLongValue) return;
    self.revisions[container] = @(revision);
    if (touching) [self.touching addObject:container]; else [self.touching removeObject:container];
    if (!self.canResume) self.layout = nil;
}
- (BOOL)acknowledgeContainer:(NSString *)container revision:(uint64_t)revision touching:(BOOL)touching {
    if (!self.valid || ![self.pending containsObject:container]) return NO;
    [self.pending removeObject:container];
    [self updatePhysicalStateForContainer:container revision:revision touching:touching];
    return YES;
}
- (void)waitForSourceReturnAfter:(NSTimeInterval)time {
    if (!self.valid || !isfinite(time) || time < 0) return;
    _reason = LCTapSyncRecoveryFollowerInput;
    self.lastFollowerBeganAt = MAX(self.lastFollowerBeganAt, time);
    self.layout = nil;
}
- (BOOL)layoutIsStable:(NSArray *)layout atTime:(NSTimeInterval)time {
    return [self layoutIsStable:layout atTime:time allowSourceGesture:NO];
}
- (BOOL)layoutIsStable:(NSArray *)layout atTime:(NSTimeInterval)time allowSourceGesture:(BOOL)allowSourceGesture {
    if (!(allowSourceGesture ? self.canResumeWithSourceGesture : self.canResume) ||
        layout.count == 0 || !isfinite(time) || time < 0) { self.layout = nil; return NO; }
    if (![self.layout isEqual:layout] || time < self.layoutSince) {
        self.layout = layout.copy;
        self.layoutSince = time;
        return NO;
    }
    return time - self.layoutSince >= 0.2;
}
- (void)invalidate {
    _valid = NO;
    [self.pending removeAllObjects];
    [self.revisions removeAllObjects];
    [self.inputRevisions removeAllObjects];
    [self.touching removeAllObjects];
    self.layout = nil;
    self.sourceReturnedAt = 0;
}
@end
