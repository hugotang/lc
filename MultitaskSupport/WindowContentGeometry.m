#import "WindowContentGeometry.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static BOOL LCWindowContentValidSize(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width >= 1 && size.height >= 1;
}

CGSize LCWindowContentLogicalSize(CGSize contentSize, CGFloat scale) {
    if (!LCWindowContentValidSize(contentSize)) return CGSizeZero;
    if (!isfinite(scale) || scale <= 0) scale = 1;
    return CGSizeMake(contentSize.width / scale, contentSize.height / scale);
}

CGRect LCWindowContentSceneFrame(CGRect contentFrame, CGFloat scale, BOOL usesHostingController,
                                 UIInterfaceOrientation orientation) {
    // The modern hosting view's transform performs the division. Legacy scene
    // settings need logical points explicitly; never divide both paths.
    if (!usesHostingController) contentFrame.size = LCWindowContentLogicalSize(contentFrame.size, scale);
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        contentFrame.size = CGSizeMake(contentFrame.size.height, contentFrame.size.width);
    }
    return contentFrame;
}

void LCWindowContentApplyHostingSize(UIView *contentView, CGSize hostSize, CGFloat scale) {
    if (!LCWindowContentValidSize(hostSize)) return;
    if (!isfinite(scale) || scale <= 0) scale = 1;
    contentView.transform = CGAffineTransformMakeScale(scale, scale);
    contentView.layer.anchorPoint = CGPointZero;
    contentView.bounds = (CGRect){CGPointZero, LCWindowContentLogicalSize(hostSize, scale)};
    contentView.layer.position = CGPointZero;
}

@interface LCWindowHostingGeometryUpdate ()
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id<LCWindowHostingGeometryUpdating> controller;
@property(nonatomic, copy) BOOL (^canUpdate)(void);
@property(nonatomic, copy) NSArray *lastGeometry;
@property(nonatomic) BOOL scheduled, needsRecheck, invalidated;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, readwrite) NSUInteger committedUpdateCount;
@end

@implementation LCWindowHostingGeometryUpdate
- (instancetype)initWithView:(UIView *)view controller:(id<LCWindowHostingGeometryUpdating>)controller
                   canUpdate:(BOOL (^)(void))canUpdate {
    if ((self = [super init])) {
        _view = view;
        _controller = controller;
        _canUpdate = [canUpdate copy];
    }
    return self;
}
- (NSArray *)geometryOfView:(UIView *)view {
    UIWindow *window = view.window;
    return @[
        [NSValue valueWithNonretainedObject:view.superview],
        [NSValue valueWithNonretainedObject:window],
        [NSValue valueWithNonretainedObject:window.windowScene],
        [NSValue valueWithCGRect:view.bounds],
        [NSValue valueWithCGRect:[view convertRect:view.bounds toView:window]],
        [NSValue valueWithCGAffineTransform:view.transform],
        [NSValue valueWithUIEdgeInsets:view.superview.safeAreaInsets],
        @(window.windowScene.interfaceOrientation), @(UIDevice.currentDevice.orientation),
        @(view.layer.cornerRadius), view.traitCollection,
    ];
}
- (void)requestUpdate {
    NSAssert(NSThread.isMainThread, @"Hosting geometry is submitted on the main thread");
    if (self.invalidated) return;
    if (self.scheduled) { self.needsRecheck = YES; return; }
    self.scheduled = YES;
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) update = weakSelf;
        if (!update || update.invalidated || generation != update.generation) return;
        UIView *view = update.view;
        id<LCWindowHostingGeometryUpdating> controller = update.controller;
        if ((!update.canUpdate || update.canUpdate()) && view.window &&
            [controller respondsToSelector:@selector(_updateSceneSettingsFromSettingsProvidersWithFence:)]) {
            // Keep the request marked scheduled during layout and submission:
            // the provider can synchronously cause another layout notification.
            [view.superview layoutIfNeeded];
            [view layoutIfNeeded];
            if (!update.invalidated && generation == update.generation && view.window &&
                (!update.canUpdate || update.canUpdate()) && LCWindowContentValidSize(view.bounds.size)) {
                NSArray *geometry = [update geometryOfView:view];
                if (![geometry isEqual:update.lastGeometry]) {
                    update.lastGeometry = geometry;
                    update.committedUpdateCount++;
                    // Preserve UIKit's own orientation, coordinate conversion
                    // and event fences rather than patching the scene by hand.
                    [controller _updateSceneSettingsFromSettingsProvidersWithFence:YES];
                }
            }
        }
        if (generation == update.generation) {
            update.scheduled = NO;
            BOOL recheck = update.needsRecheck;
            update.needsRecheck = NO;
            if (recheck && update.lastGeometry && view.window &&
                ![update.lastGeometry isEqual:[update geometryOfView:view]]) [update requestUpdate];
        }
    });
}
- (void)cancelPendingUpdate {
    NSAssert(NSThread.isMainThread, @"Hosting geometry cancellation runs on the main thread");
    self.generation++;
    self.scheduled = NO;
    self.needsRecheck = NO;
    self.lastGeometry = nil;
}
- (void)invalidate {
    [self cancelPendingUpdate];
    self.invalidated = YES;
    self.view = nil;
    self.controller = nil;
    self.canUpdate = nil;
}
@end
