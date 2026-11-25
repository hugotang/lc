#import <UIKit/UIKit.h>

// Legacy apps query UIApplication.windows even when UIKit only exposes the
// hosted guest's windows through its scene. Never combine unrelated scenes.
static inline NSArray<UIWindow *> *LCGuestWindowsFallback(NSArray<UIWindow *> *original,
                                                         NSSet<UIScene *> *scenes, UIScreen *screen) {
    if (original.count) return original;
    NSMutableArray<UIWindowScene *> *active = [NSMutableArray array];
    NSMutableArray<UIWindowScene *> *background = [NSMutableArray array];
    for (UIScene *candidate in scenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] ||
            ![candidate.session.role isEqualToString:UIWindowSceneSessionRoleApplication] ||
            candidate.activationState == UISceneActivationStateUnattached) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (scene.screen != screen) continue;
        [(scene.activationState == UISceneActivationStateBackground ? background : active) addObject:scene];
    }
    NSArray<UIWindowScene *> *candidates = active.count ? active : background;
    if (candidates.count != 1) return original;
    UIWindowScene *scene = candidates.firstObject;
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in scene.windows) {
        if (window.windowScene != scene || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
        if (window.isKeyWindow && !window.hidden) [windows insertObject:window atIndex:0];
        else [windows addObject:window];
    }
    return windows.count ? windows.array : original;
}
