#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

CGSize LCWindowContentLogicalSize(CGSize contentSize, CGFloat scale);
CGRect LCWindowContentSceneFrame(CGRect contentFrame, CGFloat scale, BOOL usesHostingController,
                                 UIInterfaceOrientation orientation);
// A transformed view's frame is not a reliable source of logical geometry.
// Assign logical bounds and a fixed origin before the scene is configured, and
// use the same operation for rotation, saved-scale changes and later resizes.
void LCWindowContentApplyHostingSize(UIView *contentView, CGSize hostSize, CGFloat scale);

NS_ASSUME_NONNULL_END
