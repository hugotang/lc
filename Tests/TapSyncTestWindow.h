#import <UIKit/UIKit.h>

// This window belongs to the scene delegate, not to any test case. Tests replace
// only their own content and leave its root controller's appearance intact.
static inline UIWindow *LCTapSyncTestHostWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window.accessibilityIdentifier isEqualToString:@"LCTapSyncTestHostWindow"]) return window;
        }
    }
    return nil;
}
