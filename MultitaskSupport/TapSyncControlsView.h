#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(16.0))
@interface LCTapSyncControlsView : UIView
@property(nonatomic, copy, nullable) void (^configure)(void);
- (void)refresh;
- (void)placeInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets;
@end

NS_ASSUME_NONNULL_END
