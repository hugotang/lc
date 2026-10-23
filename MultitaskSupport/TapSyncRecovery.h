#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCTapSyncRecoveryReason) {
    LCTapSyncRecoveryFollowerInput,
    LCTapSyncRecoveryRotation,
};

// A temporary pause belongs to one live session and is never saved to defaults.
// Every guest must cancel its old input and report idle before a new session starts.
@interface LCTapSyncRecovery : NSObject
@property(nonatomic, readonly) LCTapSyncRecoveryReason reason;
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly) BOOL canResume;
@property(nonatomic, readonly) BOOL canResumeWithSourceGesture;
@property(nonatomic, readonly) BOOL sourceHasReturned;
@property(nonatomic, copy, readonly) NSArray<NSString *> *pendingContainers;
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets reason:(LCTapSyncRecoveryReason)reason afterTime:(NSTimeInterval)time;
// Revisions make an older suspension reply unable to overwrite newer touch events.
- (BOOL)recordInputForContainer:(NSString *)container revision:(uint64_t)revision touching:(BOOL)touching began:(BOOL)began atTime:(NSTimeInterval)time;
- (BOOL)acknowledgeContainer:(NSString *)container revision:(uint64_t)revision touching:(BOOL)touching;
- (void)waitForSourceReturnAfter:(NSTimeInterval)time;
// Require an unchanged, valid layout for 200 ms after the input barrier is ready.
- (BOOL)layoutIsStable:(nullable NSArray *)layout atTime:(NSTimeInterval)time;
- (BOOL)layoutIsStable:(nullable NSArray *)layout atTime:(NSTimeInterval)time allowSourceGesture:(BOOL)allowSourceGesture;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
