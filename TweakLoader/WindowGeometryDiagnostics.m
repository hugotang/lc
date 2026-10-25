#import "WindowGeometryDiagnostics.h"
#import "WindowScreen.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSArray<NSNumber *> *LCWindowGeometrySize(CGSize size) {
    return @[@(isfinite(size.width) ? size.width : 0), @(isfinite(size.height) ? size.height : 0)];
}

static NSArray<NSNumber *> *LCWindowGeometryRect(CGRect rect) {
    return @[@(isfinite(rect.origin.x) ? rect.origin.x : 0), @(isfinite(rect.origin.y) ? rect.origin.y : 0),
        @(isfinite(rect.size.width) ? rect.size.width : 0), @(isfinite(rect.size.height) ? rect.size.height : 0)];
}

static NSDictionary *LCWindowGeometryDescribeLayer(CALayer *layer) {
    CGFloat scale = layer.contentsScale;
    NSMutableDictionary *description = [@{@"class": NSStringFromClass(layer.class),
        @"bounds": LCWindowGeometryRect(layer.bounds), @"contentsScale": @(isfinite(scale) ? scale : 0)} mutableCopy];
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        description[@"drawableSize"] = LCWindowGeometrySize(((CAMetalLayer *)layer).drawableSize);
    }
    return description;
}

NSDictionary *LCWindowGeometryDescribeWindow(UIWindow *window) {
    NSCAssert(NSThread.isMainThread, @"Guest view geometry is read on the main thread");
    NSMutableArray *renderLayers = [NSMutableArray array];
    NSMutableArray<CALayer *> *pending = [NSMutableArray arrayWithObject:window.layer];
    NSUInteger visited = 0;
    // Read the existing hierarchy only. A request must not create drawables,
    // resize views, request a layout or invoke arbitrary game getters.
    while (pending.count && visited < 512 && renderLayers.count < 32) {
        CALayer *layer = pending.lastObject;
        [pending removeLastObject];
        visited++;
        // Inspect an existing legacy layer without linking deprecated GL APIs.
        if ([layer isKindOfClass:CAMetalLayer.class] || [layer isKindOfClass:NSClassFromString(@"CAEAGLLayer")]) {
            [renderLayers addObject:LCWindowGeometryDescribeLayer(layer)];
        }
        for (CALayer *child in layer.sublayers) {
            if (pending.count >= 512) break;
            [pending addObject:child];
        }
    }
    UIView *root = window.rootViewController.viewIfLoaded;
    return @{@"class": NSStringFromClass(window.class), @"frame": LCWindowGeometryRect(window.frame),
        @"bounds": LCWindowGeometryRect(window.bounds), @"hidden": @(window.hidden),
        @"key": @(window.isKeyWindow), @"level": @(window.windowLevel),
        @"rootBounds": root ? LCWindowGeometryRect(root.bounds) : @[],
        @"renderLayers": renderLayers, @"renderTraversalTruncated": @(pending.count > 0)};
}

NSDictionary *LCWindowGeometryDiagnostics(void) {
    NSCAssert(NSThread.isMainThread, @"Guest geometry diagnostics run on the main thread");
    NSSet<UIScene *> *connected = UIApplication.sharedApplication.connectedScenes;
    UIWindow *game = LCWindowScreenGameWindowForDiagnostics();
    if (!game) {
        // Option-off diagnostics avoid input-readiness/hit-testing helpers:
        // those may instantiate view-controller content while checking alerts.
        NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
        for (UIScene *candidate in connected) {
            if (![candidate isKindOfClass:UIWindowScene.class] ||
                ![candidate.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
            UIWindowScene *scene = (UIWindowScene *)candidate;
            id<UIWindowSceneDelegate> delegate = (id)scene.delegate;
            UIWindow *delegateWindow = [delegate respondsToSelector:@selector(window)] ? delegate.window : nil;
            if (delegateWindow && delegateWindow.windowScene == scene && delegateWindow.rootViewController &&
                delegateWindow.windowLevel == UIWindowLevelNormal) {
                [candidates addObject:delegateWindow];
            } else {
                for (UIWindow *window in scene.windows) {
                    if (!window.hidden && window.rootViewController && window.windowLevel == UIWindowLevelNormal) {
                        [candidates addObject:window];
                    }
                    if (candidates.count > 1) break;
                }
            }
            if (candidates.count > 1) break;
        }
        if (candidates.count == 1) game = candidates.firstObject;
    }
    NSMutableArray *scenes = [NSMutableArray array];
    for (UIScene *candidate in connected) {
        if (![candidate isKindOfClass:UIWindowScene.class] ||
            ![candidate.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        NSMutableArray *windows = [NSMutableArray array];
        for (UIWindow *window in scene.windows) {
            // Auxiliary windows need only basic dimensions. Traverse renderer
            // layers of the bound game, even when an ad has become key.
            if (windows.count >= 16) break;
            [windows addObject:@{@"class": NSStringFromClass(window.class),
                @"bounds": LCWindowGeometryRect(window.bounds), @"frame": LCWindowGeometryRect(window.frame),
                @"hidden": @(window.hidden), @"key": @(window.isKeyWindow), @"boundGame": @(window == game)}];
        }
        [scenes addObject:@{@"bounds": LCWindowGeometryRect(scene.coordinateSpace.bounds),
            @"orientation": @(scene.interfaceOrientation), @"activationState": @(scene.activationState),
            @"windows": windows}];
        if (scenes.count >= 8) break;
    }
    return @{@"timestamp": @(NSProcessInfo.processInfo.systemUptime),
        @"screenCompatibility": LCWindowScreenGeometryForDiagnostics(), @"scenes": scenes,
        @"game": game ? LCWindowGeometryDescribeWindow(game) : @{},
        @"gameSelected": @(game != nil)};
}
