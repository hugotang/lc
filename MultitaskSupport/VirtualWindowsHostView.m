//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "WindowGridLayout.h"
#import "../LiveContainer/utils.h"

@interface VirtualWindowsHostView ()
@property(nonatomic) NSMutableArray<UIView *> *windowsInOpeningOrder;
@property(nonatomic) NSArray<UIView *> *lastArrangedWindows;
@property(nonatomic) CGRect lastArrangementBounds;
@property(nonatomic) BOOL wasAutomaticallyTiling;
@property(nonatomic) BOOL isArrangingWindows;
@end

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    self.windowsInOpeningOrder = [NSMutableArray array];
    self.lastArrangementBounds = CGRectNull;
    self.wasAutomaticallyTiling = self.automaticallyTilesWindows;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsDidChange:)
                                               name:NSUserDefaultsDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)automaticallyTilesWindows {
    return [NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoTileMultitaskWindows"];
}

- (void)defaultsDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL enabled = self.automaticallyTilesWindows;
        if (enabled != self.wasAutomaticallyTiling) {
            self.wasAutomaticallyTiling = enabled;
            self.lastArrangedWindows = nil;
            self.lastArrangementBounds = CGRectNull;
            [self setNeedsLayout];
        }
    });
}

- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    if (![self.windowsInOpeningOrder containsObject:subview]) {
        [self.windowsInOpeningOrder addObject:subview];
    }
    [self setNeedsLayout];
}

- (void)willRemoveSubview:(UIView *)subview {
    [self.windowsInOpeningOrder removeObject:subview];
    self.lastArrangedWindows = nil;
    [super willRemoveSubview:subview];
    [self setNeedsLayout];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.automaticallyTilesWindows) {
        [self arrangeVisibleWindowsInGrid:NO];
    }
}

- (void)setNeedsGridLayout {
    if (self.automaticallyTilesWindows) {
        self.lastArrangementBounds = CGRectNull;
        [self setNeedsLayout];
    }
}

- (void)arrangeWindowsInGrid {
    [self arrangeVisibleWindowsInGrid:YES];
}

- (void)arrangeVisibleWindowsInGrid:(BOOL)force {
    if (self.isArrangingWindows || !self.window) return;

    CGRect availableBounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    availableBounds = CGRectInset(availableBounds, 8, 8);
    if (availableBounds.size.width <= 0 || availableBounds.size.height <= 44) return;

    NSMutableArray<UIView *> *visibleWindows = [NSMutableArray array];
    for (UIView *view in self.windowsInOpeningOrder) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (!view.hidden && view.alpha > 0 && [vc isKindOfClass:DecoratedAppSceneViewController.class] &&
            !vc.appSceneVC.shouldIgnoreSceneUpdates) {
            [visibleWindows addObject:view];
        }
    }
    // Reflow only when the visible windows or available space change.
    if (!force && CGRectEqualToRect(availableBounds, self.lastArrangementBounds) &&
        [visibleWindows isEqualToArray:self.lastArrangedWindows]) return;

    self.lastArrangementBounds = availableBounds;
    self.lastArrangedWindows = visibleWindows.copy;
    LCWindowGridLayout layout = LCWindowGridLayoutMake(visibleWindows.count, availableBounds.size.width,
                                                      availableBounds.size.height, 8, 88);
    self.isArrangingWindows = YES;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.25 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [visibleWindows enumerateObjectsUsingBlock:^(UIView *view, NSUInteger index, BOOL *stop) {
            LCWindowGridRect tile = LCWindowGridFrame(layout, index);
            CGRect frame = CGRectMake(availableBounds.origin.x + tile.x, availableBounds.origin.y + tile.y,
                                      tile.width, tile.height);
            DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
            [vc applyGridFrame:frame];
        }];
    } completion:nil];
    self.isArrangingWindows = NO;
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // grab the frontmost app window, if it's visible pass this event to it
    UIView *frontmostView = self.subviews.lastObject;
    if(!frontmostView.hidden) {
        DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    }
    return !frontmostView.hidden;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
