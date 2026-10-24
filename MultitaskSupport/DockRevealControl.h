#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The arrow retains its placement inside a larger local host touch target.
// Near-arrow reveals do not depend on the guest delivering host edge moves.
@interface LCDockRevealControl : UIControl <UIGestureRecognizerDelegate>
- (void)showInWindow:(UIWindow *)window frame:(CGRect)frame right:(BOOL)right
          hideArrow:(BOOL)hideArrow reveal:(void (^)(void))reveal
    NS_SWIFT_NAME(show(in:frame:right:hideArrow:reveal:));
- (void)hide;
@end

// The top handle moves the Dock; an outward horizontal swipe elsewhere hides it.
@interface LCDockHideGesture : UIGestureRecognizer <UIGestureRecognizerDelegate>
- (void)attachToView:(UIView *)view ignoredTopHeight:(CGFloat)ignoredTopHeight
              right:(BOOL)right hide:(void (^)(void))hide
    NS_SWIFT_NAME(attach(to:ignoredTopHeight:right:hide:));
- (void)detach;
@end

NS_ASSUME_NONNULL_END
