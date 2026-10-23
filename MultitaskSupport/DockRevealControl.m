#import "DockRevealControl.h"
#include <math.h>

@interface LCDockRevealControl ()
@property(nonatomic) UIView *tab;
@property(nonatomic) UIImageView *arrow;
@property(nonatomic) UIScreenEdgePanGestureRecognizer *edgePan;
@property(nonatomic, copy) void (^reveal)(void);
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL revealIssued;
@end

@interface LCDockHideGesture ()
@property(nonatomic) CGFloat ignoredTopHeight;
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL hideIssued;
@property(nonatomic, copy) void (^hideDock)(void);
@end

@implementation LCDockHideGesture
- (instancetype)init {
    self = [super initWithTarget:nil action:nil];
    if (self) {
        [self addTarget:self action:@selector(handleHidePan:)];
        self.delegate = self;
        self.maximumNumberOfTouches = 1;
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)attachToView:(UIView *)view ignoredTopHeight:(CGFloat)ignoredTopHeight
              right:(BOOL)right hide:(void (^)(void))hide {
    if (!self.hideDock || self.view != view) self.hideIssued = NO;
    if (self.view != view) [view addGestureRecognizer:self];
    self.ignoredTopHeight = ignoredTopHeight;
    self.right = right;
    self.hideDock = hide;
}
- (void)detach {
    self.hideDock = nil;
    [self.view removeGestureRecognizer:self];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return self.hideDock && !self.hideIssued && [touch locationInView:self.view].y >= self.ignoredTopHeight;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!self.hideDock || self.hideIssued || !self.view || self.view.hidden || self.view.alpha < 0.01) return NO;
    CGPoint translation = [(UIPanGestureRecognizer *)gestureRecognizer translationInView:self.view];
    CGFloat outward = self.right ? translation.x : -translation.x;
    // Fail early for vertical account scrolling or movement toward the other edge.
    return outward > 0 && outward > fabs(translation.y) * 1.5;
}
- (void)handleHidePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.hideDock || self.hideIssued) return;
    CGPoint translation = [gesture translationInView:self.view];
    CGFloat outward = self.right ? translation.x : -translation.x;
    // Require a deliberate swipe; a tap or small outward drift leaves Dock open.
    if (outward >= 30 && outward > fabs(translation.y) * 1.5) {
        self.hideIssued = YES;
        self.hideDock();
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}
@end

@implementation LCDockRevealControl
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self setUp];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setUp];
    return self;
}
- (void)setUp {
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityIdentifier = @"LCDockRevealControl";
    self.tab = [UIView new];
    self.tab.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.7];
    self.tab.layer.cornerRadius = 8;
    self.tab.userInteractionEnabled = NO;
    [self addSubview:self.tab];
    self.arrow = [UIImageView new];
    self.arrow.contentMode = UIViewContentModeCenter;
    self.arrow.tintColor = UIColor.whiteColor;
    [self.tab addSubview:self.arrow];
    [self addTarget:self action:@selector(revealDock) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleRevealPan:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    [self addGestureRecognizer:pan];
}
- (void)showInWindow:(UIWindow *)window frame:(CGRect)frame right:(BOOL)right
          hideArrow:(BOOL)hideArrow reveal:(void (^)(void))reveal {
    if (self.superview != window) {
        [self removeEdgePan];
        [window addSubview:self];
    }
    self.frame = frame;
    self.right = right;
    self.reveal = reveal;
    if (self.hidden) self.revealIssued = NO;
    self.hidden = NO;
    self.alpha = 1;
    self.userInteractionEnabled = YES;
    // Hide only the artwork. The native 44pt control must remain hit-testable.
    self.tab.hidden = hideArrow;
    self.tab.alpha = 0.8;
    self.arrow.image = [UIImage systemImageNamed:right ? @"chevron.left" : @"chevron.right"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13
                                                                                                  weight:UIImageSymbolWeightBold]];
    [self setNeedsLayout];
    [window bringSubviewToFront:self];
    UIRectEdge edge = right ? UIRectEdgeRight : UIRectEdgeLeft;
    if (self.edgePan && self.edgePan.edges != edge) [self removeEdgePan];
    if (!self.edgePan) {
        self.edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(handleRevealPan:)];
        self.edgePan.edges = edge;
        self.edgePan.delegate = self;
        self.edgePan.cancelsTouchesInView = NO;
        self.edgePan.delaysTouchesBegan = NO;
        self.edgePan.delaysTouchesEnded = NO;
        [window addGestureRecognizer:self.edgePan];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.tab.frame = CGRectMake(self.right ? CGRectGetWidth(self.bounds) - 16 : 0,
                               (CGRectGetHeight(self.bounds) - 44) / 2, 16, 44);
    self.arrow.frame = self.tab.bounds;
}
- (void)hide {
    self.hidden = YES;
    self.reveal = nil;
    [self removeEdgePan];
    [self removeFromSuperview];
}
- (void)removeEdgePan {
    [self.edgePan.view removeGestureRecognizer:self.edgePan];
    self.edgePan = nil;
}
- (void)revealDock {
    if (self.hidden || !self.reveal || self.revealIssued) return;
    self.revealIssued = YES;
    self.reveal();
}
- (BOOL)accessibilityActivate {
    if (self.hidden || !self.reveal) return NO;
    [self revealDock];
    return YES;
}
- (void)handleRevealPan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged &&
        gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:gesture.view];
    CGFloat inward = self.right ? -translation.x : translation.x;
    if (inward >= 30 && inward > fabs(translation.y)) [self revealDock];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // An embedded game's recognizer must not prevent the host's reveal gesture.
    return YES;
}
@end
