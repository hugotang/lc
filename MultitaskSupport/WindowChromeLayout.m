#import "WindowChromeLayout.h"

@interface LCWindowChromeLayout ()
@property(nonatomic) NSArray<NSLayoutConstraint *> *constraints;
@property(nonatomic) NSLayoutConstraint *barPosition;
@property(nonatomic, readwrite, getter=isOverlay) BOOL overlay;
@property(nonatomic) BOOL built, bottom, hidden;
@property(nonatomic, weak) UIStackView *container;
@property(nonatomic, weak) UIView *guest;
@property(nonatomic, weak) UINavigationBar *bar;
@end

@implementation LCWindowChromeLayout
- (BOOL)applyToContainer:(UIStackView *)container guest:(UIView *)guest bar:(UINavigationBar *)bar
                 bottom:(BOOL)bottom hidden:(BOOL)hidden overlay:(BOOL)overlay {
    BOOL replaced = self.container != container || self.guest != guest || self.bar != bar;
    BOOL geometryChanged = !self.built || replaced || self.overlay != overlay ||
        (!overlay && (self.bottom != bottom || self.hidden != hidden));
    if (!geometryChanged && overlay && self.bottom != bottom) {
        self.barPosition.active = NO;
        self.barPosition = bottom ? [bar.bottomAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.bottomAnchor] :
                                   [bar.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor];
        self.barPosition.active = YES;
        self.bottom = bottom;
    }
    BOOL rebuild = geometryChanged;
    if (rebuild) {
        self.barPosition.active = NO;
        [NSLayoutConstraint deactivateConstraints:self.constraints];
        if ([container.arrangedSubviews containsObject:bar]) [container removeArrangedSubview:bar];
        [bar removeFromSuperview];
        bar.hidden = hidden;
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        guest.translatesAutoresizingMaskIntoConstraints = NO;
        NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
            [guest.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [guest.trailingAnchor constraintEqualToAnchor:container.trailingAnchor]
        ]];
        if (overlay) {
            [container addSubview:bar];
            UILayoutGuide *safe = container.safeAreaLayoutGuide;
            self.barPosition = bottom ? [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor] :
                                       [bar.topAnchor constraintEqualToAnchor:safe.topAnchor];
            [constraints addObjectsFromArray:@[
                [guest.topAnchor constraintEqualToAnchor:container.topAnchor],
                [guest.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
                [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
                [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
                [bar.heightAnchor constraintEqualToConstant:44],
                self.barPosition
            ]];
        } else {
            self.barPosition = nil;
            if (bottom) [container addArrangedSubview:bar];
            else [container insertArrangedSubview:bar atIndex:0];
            CGFloat height = hidden ? 0 : 44;
            [constraints addObjectsFromArray:@[
                [guest.topAnchor constraintEqualToAnchor:container.topAnchor constant:bottom ? 0 : height],
                [guest.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:bottom ? -height : 0],
                [bar.heightAnchor constraintEqualToConstant:height]
            ]];
        }
        self.constraints = constraints;
        [NSLayoutConstraint activateConstraints:constraints];
        self.container = container;
        self.guest = guest;
        self.bar = bar;
        self.overlay = overlay;
        self.bottom = bottom;
        self.built = YES;
    }
    self.hidden = hidden;
    bar.hidden = hidden;
    bar.alpha = hidden ? 0 : 1;
    bar.userInteractionEnabled = !hidden;
    [container bringSubviewToFront:bar];
    return geometryChanged;
}
@end
