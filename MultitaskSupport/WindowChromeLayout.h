#import <UIKit/UIKit.h>

// The guest keeps the same bounds while overlay controls are shown or hidden.
@interface LCWindowChromeLayout : NSObject
@property(nonatomic, readonly, getter=isOverlay) BOOL overlay;
- (BOOL)applyToContainer:(UIStackView *)container guest:(UIView *)guest bar:(UINavigationBar *)bar
                 bottom:(BOOL)bottom hidden:(BOOL)hidden overlay:(BOOL)overlay;
@end
