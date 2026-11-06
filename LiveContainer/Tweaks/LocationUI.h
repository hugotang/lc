#import "LocationSession.h"
NS_ASSUME_NONNULL_BEGIN
@interface LCLocationUI : NSObject
+ (UIViewController *)pickerWithInitial:(NSDictionary *)initial completion:(void (^)(NSDictionary *))completion dismissal:(void (^ _Nullable)(void))dismissal NS_SWIFT_NAME(picker(withInitial:completion:dismissal:));
+ (void)showControlsForSession:(LCLocationSession *)session inScene:(UIWindowScene *)scene NS_SWIFT_NAME(showControls(for:in:));
+ (void)showShortcutForSession:(LCLocationSession *)session inScene:(UIWindowScene *)scene;
+ (void)synchronizeShortcutForSession:(LCLocationSession *)session inScene:(UIWindowScene *)scene NS_SWIFT_NAME(synchronizeShortcut(for:in:));
+ (void)hideControlsForSession:(LCLocationSession *)session NS_SWIFT_NAME(hideControls(for:));
+ (void)installGuestControlsForSession:(LCLocationSession *)session;
@end
NS_ASSUME_NONNULL_END
