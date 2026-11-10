#import "../MultitaskSupport/TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// A short, in-memory capture of a new source gesture while followers prepare.
// Keeps complete contact boundaries; consecutive unsent moves may coalesce.
@interface LCTapSyncReturnGesture : NSObject
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly) NSTimeInterval beganAt;
@property(nonatomic, readonly) LCTapSyncMode mode;
@property(nonatomic, readonly) NSArray<NSDictionary *> *packets;
@property(nonatomic, readonly) BOOL hasActiveContacts;
- (nullable instancetype)initWithMode:(LCTapSyncMode)mode revision:(uint64_t)revision atTime:(NSTimeInterval)time;
- (BOOL)appendTap:(NSDictionary *)tap;
- (BOOL)appendTouch:(NSDictionary *)touch;
- (BOOL)appendFrame:(NSDictionary *)frame;
- (BOOL)isFreshAtTime:(NSTimeInterval)time;
@end

NS_ASSUME_NONNULL_END
