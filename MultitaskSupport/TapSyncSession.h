#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Collect all preparation replies before enabling the source, including failures/timeouts.
@interface LCTapSyncPreparation : NSObject
@property(nonatomic, copy, readonly) NSArray<NSString *> *pendingContainers;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *failures;
- (instancetype)initWithContainers:(NSArray<NSString *> *)containers;
- (BOOL)recordResult:(LCTapSyncResult)result forContainer:(NSString *)container;
- (NSDictionary<NSString *, NSNumber *> *)failuresIncludingTimeouts;
@end

// Main-thread session state. Neither active state nor queued input is persisted in a workspace.
@interface LCTapSyncSession : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, copy, readonly) NSArray<NSString *> *targets;
@property(nonatomic, readonly) LCTapSyncMode mode;
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly) NSUInteger pendingCount;
@property(nonatomic, readonly) NSUInteger coalescedMoveCount;
- (nullable instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets;
- (nullable instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets mode:(LCTapSyncMode)mode;
- (LCTapSyncResult)enqueue:(NSDictionary *)tap fromSource:(NSString *)source session:(NSString *)session
                 sequence:(uint64_t)sequence now:(NSTimeInterval)now;
- (LCTapSyncResult)enqueueTouch:(NSDictionary *)touch fromSource:(NSString *)source session:(NSString *)session
                      sequence:(uint64_t)sequence now:(NSTimeInterval)now;
- (LCTapSyncResult)enqueueTouchFrame:(NSDictionary *)frame fromSource:(NSString *)source session:(NSString *)session
                           sequence:(uint64_t)sequence now:(NSTimeInterval)now;
// Adopt one bounded return capture atomically before accepting its live continuation.
// Ordinary live input retains its four-packet queue limit while the capture drains.
- (LCTapSyncResult)enqueueSourceReturn:(NSArray<NSDictionary *> *)packets fromSource:(NSString *)source
                              session:(NSString *)session now:(NSTimeInterval)now;
// Returns a dictionary containing the original packet and sequence, in source order.
- (nullable NSDictionary *)takeNextAtTime:(NSTimeInterval)now result:(LCTapSyncResult *)result;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
