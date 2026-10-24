#import "DockRevealControl.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#include <math.h>

static UIImage *LCDockRevealTouchSurface(void) {
    static UIImage *surface;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = NO;
        format.scale = 1;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1) format:format];
        surface = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextClearRect(context.CGContext, CGRectMake(0, 0, 1, 1));
        }];
    });
    return surface;
}

// Track from touch-down rather than UIKit's pan-recognition point. A short
// reveal must not lose its first few points to the native pan's movement slop.
@interface LCDockRevealGesture : UIGestureRecognizer
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL windowRoute;
@property(nonatomic) BOOL revealEligible;
@property(nonatomic) BOOL trackingTouch;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGPoint displacement;
@end

@interface LCDockRevealControl ()
@property(nonatomic) UIView *tab;
@property(nonatomic) UIImageView *arrow;
@property(nonatomic) LCDockRevealGesture *edgePan;
@property(nonatomic) LCDockRevealGesture *tabPan;
@property(nonatomic) CGRect revealFrame;
@property(nonatomic, copy) void (^reveal)(void);
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL revealIssued;
@end

@interface LCDockHideGesture ()
@property(nonatomic) CGFloat ignoredTopHeight;
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL hideIssued;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGPoint displacement;
@property(nonatomic) BOOL trackingTouch;
@property(nonatomic, copy) void (^hideDock)(void);
@end

@implementation LCDockHideGesture
- (instancetype)init {
    self = [super initWithTarget:nil action:nil];
    if (self) {
        [self addTarget:self action:@selector(handleHideGesture:)];
        self.delegate = self;
        self.cancelsTouchesInView = YES;
        // Let a short outward drag cancel native Menu touch-down before its
        // interaction takes over. Taps are delivered when this gesture fails.
        self.delaysTouchesBegan = YES;
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
- (void)reset {
    [super reset];
    self.trackingTouch = NO;
    self.displacement = CGPointZero;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return self.hideDock && !self.hideIssued && [touch locationInView:self.view].y >= self.ignoredTopHeight;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return self.hideDock && !self.hideIssued && self.view && !self.view.hidden && self.view.alpha >= 0.01;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateCancelled;
        return;
    }
    if (self.state != UIGestureRecognizerStatePossible) return;
    if (self.trackingTouch || touches.count != 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    self.trackingTouch = YES;
    // Use window coordinates so layout/pressed-button animations cannot change
    // the measured direction. The handle is excluded by shouldReceiveTouch:.
    self.startPoint = [touches.anyObject locationInView:self.view.window];
}
- (void)updateHideIntentWithTouch:(UITouch *)touch {
    if (!self.trackingTouch || (self.state != UIGestureRecognizerStatePossible &&
        self.state != UIGestureRecognizerStateBegan && self.state != UIGestureRecognizerStateChanged)) return;
    CGPoint point = [touch locationInView:self.view.window];
    CGFloat dx = point.x - self.startPoint.x;
    CGFloat dy = fabs(point.y - self.startPoint.y);
    CGFloat outward = self.right ? dx : -dx;
    self.displacement = CGPointMake(dx, point.y - self.startPoint.y);
    if (outward <= -16 || (dy >= 20 && dy > fabs(dx) * 1.25)) {
        // Once clearly scrolling or moving inward, do not hide later in the
        // same gesture even if the finger drifts toward the edge.
        self.state = self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateCancelled;
    } else if (self.state == UIGestureRecognizerStatePossible) {
        // Native control arbitration can run before the next 6pt sample is
        // delivered. Claim clear outward intent earlier, while keeping the
        // actual hide distance at 16pt in handleHideGesture:.
        // Ambiguous initial jitter stays possible instead of failing early.
        if (outward >= 3 && outward > dy * 1.25) self.state = UIGestureRecognizerStateBegan;
    } else {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible && self.state != UIGestureRecognizerStateBegan &&
        self.state != UIGestureRecognizerStateChanged) return;
    if (touches.count != 1) {
        self.state = self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateCancelled;
        return;
    }
    [self updateHideIntentWithTouch:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count == 1) [self updateHideIntentWithTouch:touches.anyObject];
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
    else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateEnded;
    self.trackingTouch = NO;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
    else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateCancelled;
    self.trackingTouch = NO;
}
- (void)handleHideGesture:(UIGestureRecognizer *)gesture {
    if ((gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged &&
         gesture.state != UIGestureRecognizerStateEnded) || !self.hideDock || self.hideIssued) return;
    CGFloat outward = self.right ? self.displacement.x : -self.displacement.x;
    // Hide before lift, once the deliberate short swipe reaches the edge.
    if (outward < 16 || outward <= fabs(self.displacement.y) * 1.25) return;
    self.hideIssued = YES;
    self.hideDock();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // SwiftUI also routes control and menu input through non-pan recognizers,
    // sometimes on touch-down. Keep observing alongside those routes. Claiming
    // outward intent cancels the pressed view; a tap/long press still works
    // while this recognizer remains possible or fails without hiding.
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // Primary-action menus normally open on touch-down and take ownership of
    // the contact even when both recognizers can coexist. Their native button
    // must wait for this swipe to fail before opening. A tap fails at touch-up;
    // vertical/inward movement fails promptly. Account long presses do not wait.
    UIView *view = otherGestureRecognizer.view;
    if (![view isKindOfClass:UIButton.class] || ![view isDescendantOfView:self.view]) return NO;
    UIButton *button = (UIButton *)view;
    return button.menu != nil && button.showsMenuAsPrimaryAction;
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
    // Real event routing on iOS 26/27 can skip an entirely empty render layer
    // even though UIView hitTest returns this control. Hidden-arrow mode used
    // to remove our only rendered content. Keep a transparent image on the
    // host control in both modes instead of relying on a tiny background alpha.
    self.layer.contents = (__bridge id)LCDockRevealTouchSurface().CGImage;
    self.layer.contentsGravity = kCAGravityResize;
    self.layer.contentsScale = 1;
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
    self.tabPan = [[LCDockRevealGesture alloc] initWithTarget:self action:@selector(handleRevealGesture:)];
    self.tabPan.delegate = self;
    // Once a tab drag begins, it must not also activate TouchUpInside if it
    // stops before the reveal distance. A stationary tap remains available.
    self.tabPan.cancelsTouchesInView = YES;
    [self addGestureRecognizer:self.tabPan];
}
- (void)showInWindow:(UIWindow *)window frame:(CGRect)frame right:(BOOL)right
          hideArrow:(BOOL)hideArrow reveal:(void (^)(void))reveal {
    BOOL changingWindow = self.superview != window;
    if (changingWindow) {
        [self removeEdgePan];
        [window addSubview:self];
    }
    // Make the local target a real host view, including its surrounding patch.
    // A remote guest must not own contacts that narrowly miss the old 44pt tab.
    CGRect target = CGRectMake(CGRectGetMinX(frame) - (right ? 20 : 0),
                               CGRectGetMinY(frame) - 44, CGRectGetWidth(frame) + 20,
                               CGRectGetHeight(frame) + 88);
    target = CGRectIntersection(target, window.bounds);
    if (changingWindow || self.right != right || !CGRectEqualToRect(self.frame, target) ||
        !CGRectEqualToRect(self.revealFrame, frame)) {
        // A rotation or placement change invalidates an in-flight direction.
        // Repeated workspace refreshes with the same frame leave it tracking.
        self.edgePan.enabled = NO;
        self.edgePan.enabled = YES;
        self.tabPan.enabled = NO;
        self.tabPan.enabled = YES;
    }
    self.frame = target;
    self.revealFrame = frame;
    self.right = right;
    self.tabPan.right = right;
    self.reveal = reveal;
    if (self.hidden) self.revealIssued = NO;
    self.hidden = NO;
    self.alpha = 1;
    self.userInteractionEnabled = YES;
    self.tabPan.enabled = YES;
    // Hide only the artwork. The native touch target stays active.
    self.tab.hidden = hideArrow;
    self.tab.alpha = 0.8;
    self.arrow.image = [UIImage systemImageNamed:right ? @"chevron.left" : @"chevron.right"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13
                                                                                                  weight:UIImageSymbolWeightBold]];
    [self setNeedsLayout];
    [window bringSubviewToFront:self];
    if (!self.edgePan) {
        // Keep the old ability to reveal from either edge. This route observes
        // guest contacts; the larger local tab target owns near-arrow contacts
        // directly, without depending on a remote scene delivering host moves.
        self.edgePan = [[LCDockRevealGesture alloc] initWithTarget:self action:@selector(handleRevealGesture:)];
        self.edgePan.windowRoute = YES;
        self.edgePan.delegate = self;
        self.edgePan.cancelsTouchesInView = NO;
        self.edgePan.delaysTouchesBegan = NO;
        self.edgePan.delaysTouchesEnded = NO;
        [window addGestureRecognizer:self.edgePan];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect slot = CGRectOffset(self.revealFrame, -CGRectGetMinX(self.frame), -CGRectGetMinY(self.frame));
    self.tab.frame = CGRectMake(self.right ? CGRectGetMaxX(slot) - 16 : CGRectGetMinX(slot),
                               CGRectGetMidY(slot) - 22, 16, 44);
    self.arrow.frame = self.tab.bounds;
}
- (void)hide {
    self.hidden = YES;
    self.reveal = nil;
    self.tabPan.enabled = NO;
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
- (void)handleRevealGesture:(LCDockRevealGesture *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged &&
        gesture.state != UIGestureRecognizerStateEnded) return;
    if (!gesture.revealEligible) return;
    CGPoint translation = gesture.displacement;
    CGFloat inward = gesture.right ? -translation.x : translation.x;
    CGFloat distance = gesture.windowRoute ? 30 : 16;
    if (inward >= distance && inward > fabs(translation.y)) [self revealDock];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (self.hidden || !self.reveal || self.revealIssued || !self.window) return NO;
    if (gestureRecognizer != self.edgePan) return YES;
    // The tab has its own drag recognizer. Avoid two recognizers handling the
    // same contact; the window route observes uncovered guest-edge contacts.
    if ([touch.view isDescendantOfView:self]) return NO;
    CGRect bounds = self.window.bounds;
    CGPoint point = [touch locationInView:self.window];
    if (!CGRectContainsPoint(bounds, point)) return NO;
    CGFloat distance = MIN(CGRectGetMaxX(bounds) - point.x, point.x - CGRectGetMinX(bounds));
    return distance <= 44;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // Direction is resolved over successive real touch samples. Rejecting a
    // native pan here after its initial slop permanently lost diagonal starts.
    return !self.hidden && self.reveal && !self.revealIssued && self.window;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // An embedded game's recognizer must not prevent the host's reveal gesture.
    return YES;
}
@end

@implementation LCDockRevealGesture
- (void)reset {
    [super reset];
    self.trackingTouch = NO;
    self.revealEligible = NO;
    self.displacement = CGPointZero;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible || self.trackingTouch || touches.count != 1) {
        if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
        else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
            self.state = UIGestureRecognizerStateCancelled;
        return;
    }
    self.trackingTouch = YES;
    self.revealEligible = YES;
    UIView *coordinateView = self.view.window ?: self.view;
    self.startPoint = [touches.anyObject locationInView:coordinateView];
    if (self.windowRoute) self.right = self.startPoint.x > CGRectGetMidX(coordinateView.bounds);
}
- (void)updateWithTouch:(UITouch *)touch {
    if (!self.trackingTouch || (self.state != UIGestureRecognizerStatePossible &&
        self.state != UIGestureRecognizerStateBegan && self.state != UIGestureRecognizerStateChanged)) return;
    CGPoint point = [touch locationInView:self.view.window ?: self.view];
    self.displacement = CGPointMake(point.x - self.startPoint.x, point.y - self.startPoint.y);
    CGFloat inward = self.right ? -self.displacement.x : self.displacement.x;
    CGFloat vertical = fabs(self.displacement.y);
    // Tolerate initial finger jitter. A deliberate vertical/outward drag cannot
    // later turn into a reveal; local drags still consume the control's tap.
    if (inward <= -16 || (vertical >= 24 && vertical > fabs(self.displacement.x) * 1.25))
        self.revealEligible = NO;
    if (self.windowRoute && !self.revealEligible) {
        self.state = self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateCancelled;
    } else if (self.state == UIGestureRecognizerStatePossible) {
        BOOL begins = self.windowRoute ? inward >= 6 && inward > vertical :
            hypot(self.displacement.x, self.displacement.y) >= 6;
        if (begins) self.state = UIGestureRecognizerStateBegan;
    } else {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count == 1) [self updateWithTouch:touches.anyObject];
    else if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
    else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateCancelled;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count == 1) [self updateWithTouch:touches.anyObject];
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
    else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateEnded;
    self.trackingTouch = NO;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
    else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
        self.state = UIGestureRecognizerStateCancelled;
    self.trackingTouch = NO;
}
@end
