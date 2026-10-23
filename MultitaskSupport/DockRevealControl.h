#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Kept inside the host window so revealing the Dock does not depend on an
// offscreen SwiftUI view accepting input or the guest accepting an edge swipe.
@interface LCDockRevealControl : UIControl <UIGestureRecognizerDelegate>
- (void)showInWindow:(UIWindow *)window frame:(CGRect)frame right:(BOOL)right
              dimmed:(BOOL)dimmed reveal:(void (^)(void))reveal
    NS_SWIFT_NAME(show(in:frame:right:dimmed:reveal:));
- (void)hide;
@end

NS_ASSUME_NONNULL_END
