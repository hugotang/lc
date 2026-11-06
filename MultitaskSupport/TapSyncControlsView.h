#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(16.0))
@interface LCTapSyncControlsView : UIView
// Until the user saves a choice under LCTapSyncCompactControls, Icons Only is
// the default when the smallest synced window's shorter side is below 600 pt:
// every iPhone, and four windows on an iPad. An empty size means the windows
// are not known yet; iPhone then still defaults to Icons Only. This is the
// only definition of the default, shared with the setup panel.
+ (BOOL)prefersCompactControlsForSmallestWindowSize:(CGSize)size;
// Supplied by the host whenever the synced windows are laid out.
@property(nonatomic) CGSize smallestSyncedWindowSize;
@property(nonatomic, copy, nullable) void (^configure)(void);
@property(nonatomic) BOOL showsPerformance;
- (void)refresh;
- (void)placeInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets;
@end

NS_ASSUME_NONNULL_END
