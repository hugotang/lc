#import <UIKit/UIKit.h>

// The guest keeps the same bounds while overlay controls are shown or hidden.
@interface LCWindowChromeLayout : NSObject
@property(nonatomic, readonly, getter=isOverlay) BOOL overlay;
// Zero fills the available area. A valid width:height is fitted and centered.
@property(nonatomic) CGSize aspectRatio;
- (BOOL)applyToContainer:(UIStackView *)container guest:(UIView *)guest bar:(UINavigationBar *)bar
                 bottom:(BOOL)bottom hidden:(BOOL)hidden overlay:(BOOL)overlay;
@end
