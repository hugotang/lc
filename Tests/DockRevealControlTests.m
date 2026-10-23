#import <XCTest/XCTest.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "../MultitaskSupport/DockRevealControl.h"
#import "TapSyncTestWindow.h"

@interface LCDockRevealControl (Testing)
- (void)handleRevealPan:(UIPanGestureRecognizer *)gesture;
@end

@interface LCDockHideGesture (Testing)
- (void)handleHideGesture:(UIGestureRecognizer *)gesture;
@end

@interface LCDockTestTouch : UITouch
@property(nonatomic) CGPoint testLocation;
@end
@implementation LCDockTestTouch
- (CGPoint)locationInView:(UIView *)view { return self.testLocation; }
@end

@interface LCDockTestPan : UIPanGestureRecognizer
@property(nonatomic) CGPoint testTranslation;
@property(nonatomic) UIGestureRecognizerState testState;
@end
@implementation LCDockTestPan
- (CGPoint)translationInView:(UIView *)view { return self.testTranslation; }
- (UIGestureRecognizerState)state { return self.testState; }
@end

// Record the intent transitions without asking UIKit to deliver fabricated
// touches. DockGestureUITests separately drive the real recognizer with events.
@interface LCDockTestHideGesture : LCDockHideGesture
@property(nonatomic) UIGestureRecognizerState testState;
@end
@implementation LCDockTestHideGesture
- (UIGestureRecognizerState)state { return self.testState; }
- (void)setState:(UIGestureRecognizerState)state { self.testState = state; }
@end

@interface DockRevealControlTests : XCTestCase
@property(nonatomic) UIWindow *window;
@property(nonatomic) UIView *guest;
@property(nonatomic) LCDockRevealControl *control;
@property(nonatomic) NSUInteger reveals;
@property(nonatomic) NSSet<UIGestureRecognizer *> *originalGestures;
@property(nonatomic) UIEvent *testEvent;
@end

@implementation DockRevealControlTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.window = LCTapSyncTestHostWindow();
    XCTAssertNotNil(self.window);
    self.originalGestures = [NSSet setWithArray:self.window.gestureRecognizers ?: @[]];
    self.guest = [[UIView alloc] initWithFrame:self.window.bounds];
    self.guest.backgroundColor = UIColor.blackColor;
    [self.window addSubview:self.guest];
    self.control = [LCDockRevealControl new];
    self.reveals = 0;
    self.testEvent = [UIEvent new];
}
- (void)tearDown {
    [self.control hide];
    [self.guest removeFromSuperview];
    XCTAssertEqualObjects([NSSet setWithArray:self.window.gestureRecognizers ?: @[]], self.originalGestures);
    self.control = nil;
    self.guest = nil;
    self.window = nil;
    self.testEvent = nil;
    [super tearDown];
}
- (CGRect)frameForRight:(BOOL)right {
    UIEdgeInsets insets = self.window.safeAreaInsets;
    return CGRectMake(right ? CGRectGetMaxX(self.window.bounds) - insets.right - 44 : insets.left,
                      CGRectGetMidY(self.window.bounds) - 22, 44, 44);
}
- (void)showRight:(BOOL)right hideArrow:(BOOL)hideArrow {
    __weak typeof(self) weakSelf = self;
    [self.control showInWindow:self.window frame:[self frameForRight:right] right:right hideArrow:hideArrow reveal:^{
        weakSelf.reveals += 1;
    }];
    [self.control layoutIfNeeded];
}
- (NSArray<UIGestureRecognizer *> *)addedWindowGestures {
    NSMutableArray *added = [NSMutableArray array];
    for (UIGestureRecognizer *gesture in self.window.gestureRecognizers) {
        if (![self.originalGestures containsObject:gesture]) [added addObject:gesture];
    }
    return added;
}
- (void)sendPan:(CGPoint)translation state:(UIGestureRecognizerState)state {
    LCDockTestPan *pan = [LCDockTestPan new];
    pan.testTranslation = translation;
    pan.testState = state;
    [self.control handleRevealPan:pan];
}
- (void)testHiddenArrowRetainsEntireNativeTouchTargetOnBothEdges {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        XCTAssertTrue(CGRectContainsRect(self.window.bounds, self.control.frame));
        XCTAssertEqualWithAccuracy(self.control.alpha, 1, 0.001);
        UIView *artwork = self.control.subviews.firstObject;
        XCTAssertTrue(artwork.hidden);
        XCTAssertTrue(CGRectContainsRect(self.control.bounds, artwork.frame));
        XCTAssertEqualWithAccuracy(artwork.frame.size.width, 16, 0.001);
        XCTAssertEqualWithAccuracy(artwork.frame.size.height, 44, 0.001);
        XCTAssertNotNil(((UIImageView *)artwork.subviews.firstObject).image);
        for (NSNumber *x in @[@1, @22, @43]) {
            for (NSNumber *y in @[@1, @22, @43]) {
                CGPoint point = CGPointMake(self.control.frame.origin.x + x.doubleValue,
                                            self.control.frame.origin.y + y.doubleValue);
                XCTAssertEqual([self.window hitTest:point withEvent:nil], self.control);
            }
        }
        [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
        [self.control hide];
    }
    XCTAssertEqual(self.reveals, 2u);
}
- (void)testRevealStaysAboveGuestAndDoesNotCoverTheRestOfTheWindow {
    [self showRight:YES hideArrow:NO];
    XCTAssertFalse(self.control.subviews.firstObject.hidden);
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame))
                            withEvent:nil], self.control);
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.window.bounds), CGRectGetMidY(self.window.bounds))
                            withEvent:nil], self.guest);
    // A scene/window can be raised while the Dock is hidden. Refresh reclaims
    // only the small control; it does not install a covering UIWindow.
    [self.window bringSubviewToFront:self.guest];
    [self showRight:YES hideArrow:NO];
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame))
                            withEvent:nil], self.control);
    XCTAssertEqual(self.control.window, self.window);
}
- (void)testTapAndVoiceOverRevealOnceThenRearmAfterHide {
    [self showRight:YES hideArrow:NO];
    [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertTrue([self.control accessibilityActivate]);
    XCTAssertEqual(self.reveals, 1u);
    [self.control hide];
    XCTAssertFalse([self.control accessibilityActivate]);
    [self showRight:NO hideArrow:NO];
    XCTAssertTrue([self.control accessibilityActivate]);
    XCTAssertEqual(self.reveals, 2u);
}
- (void)testInwardDragsRevealFromEitherSideAndIgnoreOutwardOrVerticalDrags {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:NO];
        CGFloat inward = right.boolValue ? -1 : 1;
        NSUInteger before = self.reveals;
        [self sendPan:CGPointMake(-40 * inward, 0) state:UIGestureRecognizerStateChanged];
        [self sendPan:CGPointMake(15 * inward, 0) state:UIGestureRecognizerStateChanged];
        [self sendPan:CGPointMake(35 * inward, 60) state:UIGestureRecognizerStateChanged];
        [self sendPan:CGPointMake(40 * inward, 0) state:UIGestureRecognizerStateCancelled];
        XCTAssertEqual(self.reveals, before);
        [self sendPan:CGPointMake(40 * inward, 5) state:UIGestureRecognizerStateEnded];
        XCTAssertEqual(self.reveals, before + 1);
        [self.control hide];
    }
}
- (void)testGuestGestureCanRecognizeAlongsideEdgeAndTabDrags {
    [self showRight:YES hideArrow:NO];
    UIPanGestureRecognizer *guestPan = [UIPanGestureRecognizer new];
    [self.guest addGestureRecognizer:guestPan];
    NSArray *edges = [self addedWindowGestures];
    XCTAssertEqual(edges.count, 1u);
    UIGestureRecognizer *edge = edges.firstObject;
    XCTAssertTrue([edge isKindOfClass:UIScreenEdgePanGestureRecognizer.class]);
    XCTAssertEqual(((UIScreenEdgePanGestureRecognizer *)edge).edges, UIRectEdgeRight);
    XCTAssertFalse(edge.cancelsTouchesInView);
    XCTAssertTrue([edge.delegate gestureRecognizer:edge shouldRecognizeSimultaneouslyWithGestureRecognizer:guestPan]);
    UIGestureRecognizer *tabPan = self.control.gestureRecognizers.firstObject;
    XCTAssertTrue([tabPan.delegate gestureRecognizer:tabPan shouldRecognizeSimultaneouslyWithGestureRecognizer:guestPan]);
    [self sendPan:CGPointMake(-40, 0) state:UIGestureRecognizerStateChanged];
    XCTAssertEqual(self.reveals, 1u);
    XCTAssertTrue([self.guest.gestureRecognizers containsObject:guestPan]);
}
- (void)testSideChangesAndRepeatedHidingKeepOnlyOneOwnedEdgeRecognizer {
    for (NSUInteger index = 0; index < 12; ++index) {
        BOOL right = index % 2;
        [self showRight:right hideArrow:index % 3 == 0];
        [self showRight:right hideArrow:NO];
        NSArray *edges = [self addedWindowGestures];
        XCTAssertEqual(edges.count, 1u);
        XCTAssertEqual(((UIScreenEdgePanGestureRecognizer *)edges.firstObject).edges, right ? UIRectEdgeRight : UIRectEdgeLeft);
        [self.control hide];
        XCTAssertEqual([self addedWindowGestures].count, 0u);
        XCTAssertNil(self.control.superview);
    }
}
- (void)testMovingControlToAnotherHostRemovesTheOldEdgeRecognizer {
    [self showRight:YES hideArrow:NO];
    UIWindow *other = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    UIGestureRecognizer *unrelated = [UITapGestureRecognizer new];
    [other addGestureRecognizer:unrelated];
    NSSet *otherOriginalGestures = [NSSet setWithArray:other.gestureRecognizers];
    [self.control showInWindow:other frame:CGRectMake(0, 400, 44, 44) right:NO hideArrow:NO reveal:^{}];
    XCTAssertEqual([self addedWindowGestures].count, 0u);
    XCTAssertEqual(self.control.superview, other);
    XCTAssertTrue([other.gestureRecognizers containsObject:unrelated]);
    [self.control hide];
    XCTAssertEqualObjects([NSSet setWithArray:other.gestureRecognizers], otherOriginalGestures);
}
- (void)testOutwardHideGestureExcludesHandleAndDisabledDock {
    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(0, 100, 80, 400)];
    [self.window addSubview:dock];
    LCDockHideGesture *hide = [LCDockHideGesture new];
    [hide attachToView:dock ignoredTopHeight:50 right:YES hide:^{}];
    LCDockTestTouch *touch = [LCDockTestTouch new];
    for (NSNumber *y in @[@0, @6, @25, @49]) {
        touch.testLocation = CGPointMake(40, y.doubleValue);
        XCTAssertFalse([hide gestureRecognizer:hide shouldReceiveTouch:touch]);
    }
    touch.testLocation = CGPointMake(40, 100);
    XCTAssertTrue([hide gestureRecognizer:hide shouldReceiveTouch:touch]);
    XCTAssertTrue([hide gestureRecognizerShouldBegin:hide]);
    dock.hidden = YES;
    XCTAssertFalse([hide gestureRecognizerShouldBegin:hide]);
    dock.hidden = NO;
    dock.alpha = 0;
    XCTAssertFalse([hide gestureRecognizerShouldBegin:hide]);
    dock.alpha = 1;
    UIPanGestureRecognizer *scroll = [UIPanGestureRecognizer new];
    XCTAssertTrue([hide gestureRecognizer:hide shouldRecognizeSimultaneouslyWithGestureRecognizer:scroll]);
    XCTAssertTrue(hide.cancelsTouchesInView);
    XCTAssertFalse(hide.delaysTouchesBegan);
    XCTAssertFalse(hide.delaysTouchesEnded);
    [hide detach];
    XCTAssertFalse([hide gestureRecognizerShouldBegin:hide]);
    XCTAssertNil(hide.view);
    [dock removeFromSuperview];
}
- (LCDockTestTouch *)beginHide:(LCDockTestHideGesture *)hide {
    [hide reset];
    hide.testState = UIGestureRecognizerStatePossible;
    LCDockTestTouch *touch = [LCDockTestTouch new];
    touch.testLocation = CGPointMake(40, 100);
    [hide touchesBegan:[NSSet setWithObject:touch] withEvent:self.testEvent];
    return touch;
}
- (void)moveHide:(LCDockTestHideGesture *)hide touch:(LCDockTestTouch *)touch by:(CGPoint)translation {
    touch.testLocation = CGPointMake(40 + translation.x, 100 + translation.y);
    [hide touchesMoved:[NSSet setWithObject:touch] withEvent:self.testEvent];
    [hide handleHideGesture:hide];
}
- (void)testShortOutwardSwipeHidesBeforeLiftDespiteInitialJitterOnEitherSide {
    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(0, 100, 56, 400)];
    [self.window addSubview:dock];
    LCDockTestHideGesture *hide = [LCDockTestHideGesture new];
    __block NSUInteger hidden = 0;
    for (NSNumber *right in @[@NO, @YES]) {
        [hide attachToView:dock ignoredTopHeight:50 right:right.boolValue hide:^{ hidden += 1; }];
        CGFloat outward = right.boolValue ? 1 : -1;
        NSUInteger before = hidden;
        LCDockTestTouch *touch = [self beginHide:hide];
        [self moveHide:hide touch:touch by:CGPointMake(4 * outward, 8)];
        XCTAssertEqual(hide.state, UIGestureRecognizerStatePossible);
        [self moveHide:hide touch:touch by:CGPointMake(15 * outward, 8)];
        XCTAssertEqual(hidden, before);
        [self moveHide:hide touch:touch by:CGPointMake(16 * outward, 8)];
        XCTAssertEqual(hide.state, UIGestureRecognizerStateRecognized);
        XCTAssertEqual(hidden, before + 1);
        [hide handleHideGesture:hide];
        XCTAssertEqual(hidden, before + 1);
        XCTAssertFalse([hide gestureRecognizerShouldBegin:hide]);
        [hide detach];
    }
    XCTAssertEqual(hidden, 2u);
    [dock removeFromSuperview];
}
- (void)testVerticalOrInwardIntentCannotBecomeHideLaterInTheSameGesture {
    LCDockTestHideGesture *hide = [LCDockTestHideGesture new];
    __block NSUInteger hidden = 0;
    [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{ hidden += 1; }];
    for (NSValue *value in @[[NSValue valueWithCGPoint:CGPointMake(6, 22)],
                            [NSValue valueWithCGPoint:CGPointMake(-16, 0)]]) {
        LCDockTestTouch *touch = [self beginHide:hide];
        [self moveHide:hide touch:touch by:value.CGPointValue];
        XCTAssertEqual(hide.state, UIGestureRecognizerStateFailed);
        [self moveHide:hide touch:touch by:CGPointMake(50, 0)];
        XCTAssertEqual(hidden, 0u);
    }
    // Ambiguous diagonal motion stays possible until its accumulated direction
    // is clear; it must not cancel a button or hide merely at 16pt of travel.
    LCDockTestTouch *touch = [self beginHide:hide];
    [self moveHide:hide touch:touch by:CGPointMake(16, 16)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStatePossible);
    [hide touchesEnded:[NSSet setWithObject:touch] withEvent:self.testEvent];
    [hide handleHideGesture:hide];
    XCTAssertEqual(hidden, 0u);
    [hide detach];
}
- (void)testTapsSmallDriftsCancellationAndMultipleFingersDoNotHide {
    LCDockTestHideGesture *hide = [LCDockTestHideGesture new];
    __block NSUInteger hidden = 0;
    [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{ hidden += 1; }];
    for (NSNumber *distance in @[@0, @5, @15]) {
        LCDockTestTouch *touch = [self beginHide:hide];
        [self moveHide:hide touch:touch by:CGPointMake(distance.doubleValue, 0)];
        [hide touchesEnded:[NSSet setWithObject:touch] withEvent:self.testEvent];
        [hide handleHideGesture:hide];
        XCTAssertEqual(hide.state, UIGestureRecognizerStateFailed);
        XCTAssertEqual(hidden, 0u);
    }
    LCDockTestTouch *touch = [self beginHide:hide];
    [self moveHide:hide touch:touch by:CGPointMake(10, 0)];
    [hide touchesCancelled:[NSSet setWithObject:touch] withEvent:self.testEvent];
    [self moveHide:hide touch:touch by:CGPointMake(30, 0)];
    XCTAssertEqual(hidden, 0u);
    touch = [self beginHide:hide];
    [hide touchesBegan:[NSSet setWithObject:[LCDockTestTouch new]] withEvent:self.testEvent];
    [self moveHide:hide touch:touch by:CGPointMake(30, 0)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStateFailed);
    XCTAssertEqual(hidden, 0u);
    [hide reset];
    hide.testState = UIGestureRecognizerStatePossible;
    [hide touchesBegan:[NSSet setWithObjects:touch, [LCDockTestTouch new], nil] withEvent:self.testEvent];
    XCTAssertEqual(hide.state, UIGestureRecognizerStateFailed);
    [hide detach];
}
- (void)testHideRearmsOnlyAfterDetachAndKeepsOtherRecognizers {
    LCDockTestHideGesture *hide = [LCDockTestHideGesture new];
    UIPanGestureRecognizer *unrelated = [UIPanGestureRecognizer new];
    [self.guest addGestureRecognizer:unrelated];
    __block NSUInteger hidden = 0;
    for (NSUInteger index = 0; index < 4; ++index) {
        [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{ hidden += 1; }];
        LCDockTestTouch *touch = [self beginHide:hide];
        [self moveHide:hide touch:touch by:CGPointMake(20, 0)];
        XCTAssertEqual(hidden, index + 1);
        [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{ hidden += 1; }];
        [hide handleHideGesture:hide];
        XCTAssertEqual(hidden, index + 1);
        [hide detach];
        XCTAssertTrue([self.guest.gestureRecognizers containsObject:unrelated]);
        XCTAssertFalse([self.guest.gestureRecognizers containsObject:hide]);
    }
}
@end
