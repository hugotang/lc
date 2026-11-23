#import "WindowMinimization.h"
#import <QuartzCore/QuartzCore.h>

@interface LCWindowMinimization ()
@property(nonatomic, weak, readwrite) UIView *view;
@property(nonatomic, readwrite, getter=isMinimized) BOOL minimized;
@property(nonatomic, copy) BOOL (^availability)(void);
@property(nonatomic) NSUInteger generation;
@end

@implementation LCWindowMinimization
- (instancetype)initWithView:(UIView *)view availability:(BOOL (^)(void))availability {
    self = [super init];
    if (self) {
        _view = view;
        _availability = [availability copy];
    }
    return self;
}

- (BOOL)canRestore {
    return self.isMinimized && self.view.superview && self.view.window && self.availability();
}

- (BOOL)minimize {
    UIView *view = self.view;
    if (self.isMinimized || !view || view.hidden) return NO;
    self.minimized = YES;
    NSUInteger generation = ++self.generation;
    [view.layer removeAllAnimations];
    view.transform = CGAffineTransformIdentity;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.3 delay:0
                        options:UIViewAnimationOptionCurveEaseInOut animations:^{
        view.alpha = 0;
        view.transform = CGAffineTransformMakeScale(0.1, 0.1);
    } completion:^(BOOL finished) {
        if (!finished || self.generation != generation || !self.isMinimized) return;
        view.hidden = YES;
        view.transform = CGAffineTransformIdentity;
        // Hidden windows need no stacking change. Keeping their place preserves floating overlaps on Restore All.
        [view.superview setNeedsLayout];
    }];
    [view.superview setNeedsLayout];
    return YES;
}

- (void)invalidate {
    if (!self.isMinimized) return;
    self.minimized = NO;
    ++self.generation;
    [self.view.layer removeAllAnimations];
    self.view.transform = CGAffineTransformIdentity;
}

- (BOOL)restore {
    if (!self.canRestore) return NO;
    [self invalidate];
    self.view.hidden = NO;
    self.view.alpha = 1;
    [self.view.superview setNeedsLayout];
    return YES;
}

+ (NSUInteger)restoreWindows:(NSArray<LCWindowMinimization *> *)windows
                      inHost:(UIView *)host layout:(void (^)(NSArray<UIView *> *restored))layout {
    if (!host.window) return 0;
    NSMutableArray<UIView *> *restored = [NSMutableArray array];
    [UIView performWithoutAnimation:^{
        for (LCWindowMinimization *window in windows) {
            if (window.view.superview == host && [window restore]) [restored addObject:window.view];
        }
        if (restored.count > 0) layout(restored.copy);
    }];
    return restored.count;
}
@end
