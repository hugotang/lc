#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(16.0))
@interface LCTapSyncControlsView : UIView
// Icons Only until the user saves a choice under LCTapSyncCompactControls.
// The only definition of the default, shared with the setup panel.
@property(class, nonatomic, readonly) BOOL compactControlsByDefault;
@property(nonatomic, copy, nullable) void (^configure)(void);
@property(nonatomic) BOOL showsPerformance;
- (void)refresh;
- (void)placeInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets;
@end

NS_ASSUME_NONNULL_END
