#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

CGSize LCWindowContentLogicalSize(CGSize contentSize, CGFloat scale);
CGRect LCWindowContentSceneFrame(CGRect contentFrame, CGFloat scale, BOOL usesHostingController,
                                 UIInterfaceOrientation orientation);
// A transformed view's frame is not a reliable source of logical geometry.
// Assign logical bounds and a fixed origin before the scene is configured, and
// use the same operation for rotation, saved-scale changes and later resizes.
void LCWindowContentApplyHostingSize(UIView *contentView, CGSize hostSize, CGFloat scale);

// Submit the completed view geometry through UIKit's hosting controller. A
// hosting view's bounds alone do not establish delivery to the remote scene.
@protocol LCWindowHostingGeometryUpdating <NSObject>
- (void)_updateSceneSettingsFromSettingsProvidersWithFence:(BOOL)fence;
@end

@interface LCWindowHostingGeometryUpdate : NSObject
@property(nonatomic, readonly) NSUInteger committedUpdateCount;
- (instancetype)initWithView:(UIView *)view controller:(id<LCWindowHostingGeometryUpdating>)controller
                   canUpdate:(BOOL (^ _Nullable)(void))canUpdate;
- (void)requestUpdate;
- (void)cancelPendingUpdate;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
