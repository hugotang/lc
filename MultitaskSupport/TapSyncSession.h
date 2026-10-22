#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Main-thread session state. Neither active state nor queued input is persisted in a workspace.
@interface LCTapSyncSession : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, copy, readonly) NSArray<NSString *> *targets;
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly) NSUInteger pendingCount;
- (nullable instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets;
- (LCTapSyncResult)enqueue:(NSDictionary *)tap fromSource:(NSString *)source session:(NSString *)session
                 sequence:(uint64_t)sequence now:(NSTimeInterval)now;
// Returns a dictionary containing the original packet and sequence, in source order.
- (nullable NSDictionary *)takeNextAtTime:(NSTimeInterval)now result:(LCTapSyncResult *)result;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
