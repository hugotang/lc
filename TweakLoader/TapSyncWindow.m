#import "TapSyncWindow.h"
#import <QuartzCore/QuartzCore.h>

static BOOL LCTapSyncViewIsVisible(UIView *view) {
    return !view.hidden && view.alpha > 0.01 && !CGRectIsEmpty(view.bounds);
}

static BOOL LCTapSyncViewHasContentOrInput(UIView *view) {
    CGColorRef background = view.backgroundColor.CGColor, border = view.layer.borderColor;
    if ((background && CGColorGetAlpha(background) > 0.01) || view.layer.contents ||
        (view.layer.borderWidth > 0 && border && CGColorGetAlpha(border) > 0.01)) return YES;
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return YES;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) return YES;
    if ([view isKindOfClass:UIVisualEffectView.class] && ((UIVisualEffectView *)view).effect) return YES;
    if ([view isKindOfClass:UIControl.class] && ((UIControl *)view).enabled) return YES;
    if ([view.layer isKindOfClass:CAMetalLayer.class] || [view.layer isKindOfClass:NSClassFromString(@"CAEAGLLayer")]) return YES;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) if (gesture.enabled) return YES;
    // Transparent structural views are not content. Custom drawing/touch receivers are.
    Class base = [view isKindOfClass:UIWindow.class] ? UIWindow.class : UIView.class;
    for (NSString *name in @[@"drawRect:", @"touchesBegan:withEvent:", @"touchesMoved:withEvent:",
                             @"touchesEnded:withEvent:", @"touchesCancelled:withEvent:"]) {
        SEL selector = NSSelectorFromString(name);
        if ([view.class instanceMethodForSelector:selector] != [base instanceMethodForSelector:selector]) return YES;
    }
    return NO;
}

static BOOL LCTapSyncWindowReceivesTouchesInRect(UIWindow *window, UIWindow *guest, CGRect rect) {
    // Include corners so a small edge control is not lost in a whole-window centre check.
    CGFloat inset = MIN(0.5, MIN(rect.size.width, rect.size.height) / 4);
    CGPoint points[] = {
        CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)),
        CGPointMake(CGRectGetMinX(rect) + inset, CGRectGetMinY(rect) + inset),
        CGPointMake(CGRectGetMaxX(rect) - inset, CGRectGetMinY(rect) + inset),
        CGPointMake(CGRectGetMinX(rect) + inset, CGRectGetMaxY(rect) - inset),
        CGPointMake(CGRectGetMaxX(rect) - inset, CGRectGetMaxY(rect) - inset),
    };
    for (NSUInteger i = 0; i < sizeof(points) / sizeof(points[0]); i++) {
        CGPoint point = [guest convertPoint:points[i] toWindow:window];
        if ([window hitTest:point withEvent:nil]) return YES;
    }
    return NO;
}

static BOOL LCTapSyncWindowHasVisibleAlert(UIWindow *window, UIWindow *guest) {
    NSMutableArray<UIViewController *> *pending = [NSMutableArray array];
    if (window.rootViewController) [pending addObject:window.rootViewController];
    NSUInteger remaining = 128;
    while (pending.count && remaining--) {
        UIViewController *controller = pending.lastObject;
        [pending removeLastObject];
        if ([controller isKindOfClass:UIAlertController.class] && !controller.isBeingDismissed &&
            controller.isViewLoaded && controller.view.window == window && LCTapSyncViewIsVisible(controller.view) &&
            CGRectIntersectsRect([controller.view convertRect:controller.view.bounds toView:guest], guest.bounds)) return YES;
        if (controller.presentedViewController) [pending addObject:controller.presentedViewController];
        [pending addObjectsFromArray:controller.childViewControllers];
    }
    return NO;
}

BOOL LCTapSyncWindowIsCovered(UIWindow *guest, NSArray<UIWindow *> *windows) {
    if (LCTapSyncWindowHasVisibleAlert(guest, guest)) return YES;
    for (UIWindow *window in windows) {
        if (window == guest || window.windowScene != guest.windowScene || window.windowLevel <= guest.windowLevel ||
            !window.userInteractionEnabled || !window.rootViewController || !LCTapSyncViewIsVisible(window)) continue;
        CGRect overlap = CGRectIntersection(guest.bounds, [window convertRect:window.bounds toWindow:guest]);
        if (CGRectIsEmpty(overlap) || CGRectIsNull(overlap)) continue;
        if (LCTapSyncWindowHasVisibleAlert(window, guest)) return YES;
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
        NSUInteger visited = 0;
        while (pending.count) {
            // Bound work on guest input paths. An unusually large overlay stays paused.
            if (++visited > 256) return YES;
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if (!LCTapSyncViewIsVisible(view)) continue;
            CGRect rect = CGRectIntersection(overlap, [view convertRect:view.bounds toView:guest]);
            if (CGRectIsEmpty(rect) || CGRectIsNull(rect)) continue;
            if (LCTapSyncViewHasContentOrInput(view) && LCTapSyncWindowReceivesTouchesInRect(window, guest, rect)) return YES;
            [pending addObjectsFromArray:view.subviews];
        }
    }
    return NO;
}

UIWindow *LCTapSyncFindGuestWindow(NSSet<UIScene *> *scenes, LCTapSyncResult *result) {
    if (result) *result = LCTapSyncResultSceneInactive;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (result) *result = LCTapSyncResultWindowNotReady;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.windowLevel == UIWindowLevelNormal && window.userInteractionEnabled &&
                window.rootViewController && LCTapSyncViewIsVisible(window)) [windows addObject:window];
        }
    }
    UIWindow *keyWindow = nil;
    for (UIWindow *window in windows) {
        if (!window.isKeyWindow) continue;
        if (keyWindow) return nil;
        keyWindow = window;
    }
    UIWindow *guest = keyWindow ?: (windows.count == 1 ? windows.firstObject : nil);
    if (!guest) return nil;
    if (LCTapSyncWindowIsCovered(guest, guest.windowScene.windows)) {
        if (result) *result = LCTapSyncResultWindowCovered;
        return nil;
    }
    if (result) *result = LCTapSyncResultAccepted;
    return guest;
}
