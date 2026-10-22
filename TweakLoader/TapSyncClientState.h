#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Guest input state that must outlive an individual replay/session. Main queue only.
@interface LCTapSyncClientState : NSObject
@property(nonatomic, copy, nullable) NSString *session;
- (void)rememberSyntheticTouch:(id)touch;
- (BOOL)ownsTouch:(id)touch;
// Capture now, execute after UIKit finishes the event that caused the interruption.
// A stopped/replaced session makes the returned action a no-op.
- (nullable dispatch_block_t)actionForCurrentSession:(dispatch_block_t)action;
// Bounded recovery only after a transport failure; zero means wait for user activity.
- (NSTimeInterval)nextConnectionRetryDelay;
- (void)resetConnectionRecovery;
@end

NS_ASSUME_NONNULL_END
