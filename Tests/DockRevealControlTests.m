#import <XCTest/XCTest.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "../MultitaskSupport/DockRevealControl.h"
#import "TapSyncTestWindow.h"

@interface LCDockRevealControl (Testing)
- (void)handleRevealGesture:(UIGestureRecognizer *)gesture;
@end

// Test the production touch-state policy with deterministic contacts. Actual
// UIKit hit testing, cancellation and gesture arbitration use the UI suite.
@interface LCDockRevealGesture : UIGestureRecognizer
@property(nonatomic) BOOL right;
@property(nonatomic) BOOL windowRoute;
@property(nonatomic) BOOL revealEligible;
@property(nonatomic) CGPoint displacement;
@end

@interface LCDockHideGesture (Testing)
- (void)handleHideGesture:(UIGestureRecognizer *)gesture;
@end

@interface LCDockTestTouch : UITouch
@property(nonatomic) CGPoint testLocation;
@property(nonatomic) UIView *testView;
@end
@implementation LCDockTestTouch
- (CGPoint)locationInView:(UIView *)view { return self.testLocation; }
- (UIView *)view { return self.testView; }
@end

@interface LCDockTestRevealGesture : LCDockRevealGesture
@property(nonatomic) UIGestureRecognizerState testState;
@end
@implementation LCDockTestRevealGesture
- (UIGestureRecognizerState)state { return self.testState; }
- (void)setState:(UIGestureRecognizerState)state { self.testState = state; }
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
    LCDockTestRevealGesture *gesture = [LCDockTestRevealGesture new];
    gesture.right = [[self.control valueForKey:@"right"] boolValue];
    gesture.revealEligible = YES;
    gesture.displacement = translation;
    gesture.testState = state;
    [self.control handleRevealGesture:gesture];
}
- (void)testHiddenArrowRetainsEntireNativeTouchTargetOnBothEdges {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        XCTAssertTrue(CGRectContainsRect(self.window.bounds, self.control.frame));
        XCTAssertEqualWithAccuracy(self.control.frame.size.width, 64, 0.001);
        XCTAssertEqualWithAccuracy(self.control.frame.size.height, 132, 0.001);
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
- (void)testHiddenArrowRetainsATransparentImageSurfaceAcrossVisibilityChanges {
    id contents = self.control.layer.contents;
    XCTAssertNotNil(contents);
    CGImageRef image = (__bridge CGImageRef)contents;
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)contents), CGImageGetTypeID());
    XCTAssertEqual(CGImageGetWidth(image), 1u);
    XCTAssertEqual(CGImageGetHeight(image), 1u);
    uint8_t pixel[4] = {255, 255, 255, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    XCTAssertNotEqual(context, NULL);
    CGContextClearRect(context, CGRectMake(0, 0, 1, 1));
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
    XCTAssertEqual(pixel[3], 0u);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *hideArrow in @[@NO, @YES, @NO, @YES]) {
            [self showRight:right.boolValue hideArrow:hideArrow.boolValue];
            XCTAssertEqual(self.control.layer.contents, contents);
            XCTAssertFalse(self.control.layer.hidden);
            XCTAssertEqualWithAccuracy(self.control.layer.opacity, 1, 0.001);
            XCTAssertEqual(self.control.subviews.firstObject.hidden, hideArrow.boolValue);
            XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame))
                                    withEvent:nil], self.control);
            [self.control hide];
        }
    }
    LCDockRevealControl *second = [LCDockRevealControl new];
    XCTAssertEqual(second.layer.contents, contents);
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
- (void)testSwipeOnlyIgnoresTapsButRetainsInwardRevealAndVoiceOver {
    self.control.tapToRevealEnabled = NO;
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        NSUInteger before = self.reveals;
        for (NSUInteger index = 0; index < 4; index++) {
            [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
        XCTAssertEqual(self.reveals, before);
        XCTAssertFalse([[self.control valueForKey:@"revealIssued"] boolValue]);
        CGFloat inward = right.boolValue ? -1 : 1;
        [self sendPan:CGPointMake(inward * 22, 5) state:UIGestureRecognizerStateChanged];
        XCTAssertEqual(self.reveals, before + 1);
        [self.control hide];
        [self showRight:right.boolValue hideArrow:YES];
        XCTAssertTrue([self.control accessibilityActivate]);
        XCTAssertEqual(self.reveals, before + 2);
        [self.control hide];
    }
}
- (void)testTapRevealPreferenceCanChangeWhileHiddenWithoutRecreatingTheControl {
    [self showRight:YES hideArrow:YES];
    XCTAssertTrue(self.control.tapToRevealEnabled);
    self.control.tapToRevealEnabled = NO;
    [self showRight:YES hideArrow:YES];
    [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqual(self.reveals, 0u);
    self.control.tapToRevealEnabled = YES;
    [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqual(self.reveals, 1u);
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
    XCTAssertTrue([edge isKindOfClass:LCDockRevealGesture.class]);
    XCTAssertFalse([edge isKindOfClass:UIScreenEdgePanGestureRecognizer.class]);
    XCTAssertFalse(edge.cancelsTouchesInView);
    XCTAssertTrue([edge.delegate gestureRecognizer:edge shouldRecognizeSimultaneouslyWithGestureRecognizer:guestPan]);
    UIGestureRecognizer *tabPan = self.control.gestureRecognizers.firstObject;
    XCTAssertTrue([tabPan.delegate gestureRecognizer:tabPan shouldRecognizeSimultaneouslyWithGestureRecognizer:guestPan]);
    XCTAssertTrue(tabPan.cancelsTouchesInView);
    XCTAssertTrue([tabPan isKindOfClass:LCDockRevealGesture.class]);
    [self sendPan:CGPointMake(-40, 0) state:UIGestureRecognizerStateChanged];
    XCTAssertEqual(self.reveals, 1u);
    XCTAssertTrue([self.guest.gestureRecognizers containsObject:guestPan]);
}
- (void)testSideChangesAndRepeatedHidingKeepOnlyOneOwnedEdgeRecognizer {
    for (NSUInteger index = 0; index < 12; ++index) {
        BOOL right = index % 2;
        [self showRight:right hideArrow:index % 3 == 0];
        [self showRight:right hideArrow:NO];
        NSArray<UIGestureRecognizer *> *edges = [self addedWindowGestures];
        XCTAssertEqual(edges.count, 1u);
        XCTAssertEqual(edges.firstObject.view, self.window);
        LCDockTestTouch *touch = [LCDockTestTouch new];
        touch.testView = self.guest;
        touch.testLocation = CGPointMake(right ? CGRectGetMaxX(self.window.bounds) - 22 : CGRectGetMinX(self.window.bounds) + 22,
                                       CGRectGetMidY(self.window.bounds) - 100);
        XCTAssertTrue([self.control gestureRecognizer:edges.firstObject shouldReceiveTouch:touch]);
        [self.control hide];
        XCTAssertEqual([self addedWindowGestures].count, 0u);
        XCTAssertNil(self.control.superview);
    }
}
- (void)testWindowGestureAcceptsBoth44PointEdgeBandsAtTouchDown {
    LCDockTestTouch *touch = [LCDockTestTouch new];
    touch.testView = self.guest;
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        UIGestureRecognizer *edge = [self addedWindowGestures].firstObject;
        for (NSNumber *startRight in @[@NO, @YES]) {
            for (NSNumber *distance in @[@2, @22, @44, @45, @100]) {
                touch.testLocation = CGPointMake(startRight.boolValue ? CGRectGetMaxX(self.window.bounds) - distance.doubleValue :
                                                                        CGRectGetMinX(self.window.bounds) + distance.doubleValue,
                                               CGRectGetMidY(self.window.bounds) - 100);
                XCTAssertEqual([self.control gestureRecognizer:edge shouldReceiveTouch:touch], distance.doubleValue <= 44);
            }
        }
        // Tab contacts belong to the local pan, and a touch beyond window
        // bounds must not be mistaken for a valid edge contact.
        touch.testView = self.control;
        touch.testLocation = CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame));
        XCTAssertFalse([self.control gestureRecognizer:edge shouldReceiveTouch:touch]);
        XCTAssertTrue([self.control gestureRecognizer:self.control.gestureRecognizers.firstObject shouldReceiveTouch:touch]);
        touch.testView = self.guest;
        touch.testLocation = CGPointMake(CGRectGetMinX(self.window.bounds) - 1, 100);
        XCTAssertFalse([self.control gestureRecognizer:edge shouldReceiveTouch:touch]);
        [self.control hide];
        XCTAssertFalse([self.control gestureRecognizer:edge shouldReceiveTouch:touch]);
    }
}
- (void)testRevealGestureDoesNotRejectInitialDiagonalJitterInTheBeginDelegate {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        UIGestureRecognizer *edge = [self addedWindowGestures].firstObject;
        XCTAssertTrue([self.control gestureRecognizerShouldBegin:edge]);
        XCTAssertTrue([self.control gestureRecognizerShouldBegin:self.control.gestureRecognizers.firstObject]);
        [self.control accessibilityActivate];
        XCTAssertFalse([self.control gestureRecognizerShouldBegin:edge]);
        [self.control hide];
        XCTAssertFalse([self.control gestureRecognizerShouldBegin:edge]);
    }
}
- (LCDockTestTouch *)beginReveal:(LCDockTestRevealGesture *)gesture at:(CGPoint)point {
    [gesture reset];
    gesture.testState = UIGestureRecognizerStatePossible;
    LCDockTestTouch *touch = [LCDockTestTouch new];
    touch.testLocation = point;
    [gesture touchesBegan:[NSSet setWithObject:touch] withEvent:self.testEvent];
    return touch;
}
- (void)moveReveal:(LCDockTestRevealGesture *)gesture touch:(LCDockTestTouch *)touch to:(CGPoint)point {
    touch.testLocation = point;
    [gesture touchesMoved:[NSSet setWithObject:touch] withEvent:self.testEvent];
    [self.control handleRevealGesture:gesture];
}
- (void)testNearArrowTargetIncludesMissedLandingsWithoutMovingTheArtwork {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        CGRect original = [self frameForRight:right.boolValue];
        CGFloat sign = right.boolValue ? -1 : 1;
        for (NSValue *offset in @[[NSValue valueWithCGPoint:CGPointMake(0, -40)],
                                  [NSValue valueWithCGPoint:CGPointMake(0, 40)],
                                  [NSValue valueWithCGPoint:CGPointMake(28, 0)]]) {
            CGPoint point = CGPointMake(CGRectGetMidX(original) + offset.CGPointValue.x * sign,
                                       CGRectGetMidY(original) + offset.CGPointValue.y);
            XCTAssertEqual([self.window hitTest:point withEvent:nil], self.control);
        }
        CGPoint outside = CGPointMake(CGRectGetMidX(original), CGRectGetMidY(original) + 70);
        XCTAssertEqual([self.window hitTest:outside withEvent:nil], self.guest);
        UIView *artwork = self.control.subviews.firstObject;
        CGRect inWindow = [self.control convertRect:artwork.frame toView:self.window];
        XCTAssertEqualWithAccuracy(CGRectGetMidY(inWindow), CGRectGetMidY(original), 0.001);
        XCTAssertEqualWithAccuracy(right.boolValue ? CGRectGetMaxX(inWindow) : CGRectGetMinX(inWindow),
                                  right.boolValue ? CGRectGetMaxX(original) : CGRectGetMinX(original), 0.001);
        [self.control hide];
    }
}
- (void)testLocalRevealCountsFromTouchDownAndToleratesInitialJitter {
    LCDockTestRevealGesture *gesture = [LCDockTestRevealGesture new];
    [self.control addGestureRecognizer:gesture];
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue hideArrow:YES];
        gesture.right = right.boolValue;
        CGFloat inward = right.boolValue ? -1 : 1;
        NSUInteger before = self.reveals;
        LCDockTestTouch *touch = [self beginReveal:gesture at:CGPointMake(100, 100)];
        [self moveReveal:gesture touch:touch to:CGPointMake(100 + 4 * inward, 112)];
        XCTAssertEqual(gesture.state, UIGestureRecognizerStateBegan);
        XCTAssertEqual(self.reveals, before);
        [self moveReveal:gesture touch:touch to:CGPointMake(100 + 15 * inward, 108)];
        XCTAssertEqual(self.reveals, before);
        [self moveReveal:gesture touch:touch to:CGPointMake(100 + 16 * inward, 108)];
        XCTAssertEqual(self.reveals, before + 1);
        [self.control hide];
    }
    [self.control removeGestureRecognizer:gesture];
}
- (void)testNearArrowTargetClipsAtHostTopAndBottomAndUnchangedRefreshRetainsGestures {
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *bottom in @[@NO, @YES]) {
            CGRect frame = [self frameForRight:right.boolValue];
            frame.origin.y = bottom.boolValue ? CGRectGetMaxY(self.window.bounds) - 52 : CGRectGetMinY(self.window.bounds) + 8;
            [self.control showInWindow:self.window frame:frame right:right.boolValue hideArrow:YES reveal:^{}];
            [self.control layoutIfNeeded];
            XCTAssertTrue(CGRectContainsRect(self.window.bounds, self.control.frame));
            CGRect artwork = [self.control convertRect:self.control.subviews.firstObject.frame toView:self.window];
            XCTAssertEqualWithAccuracy(CGRectGetMidY(artwork), CGRectGetMidY(frame), 0.001);
            UIGestureRecognizer *edge = [self addedWindowGestures].firstObject;
            UIGestureRecognizer *local = self.control.gestureRecognizers.firstObject;
            for (NSUInteger index = 0; index < 4; ++index)
                [self.control showInWindow:self.window frame:frame right:right.boolValue hideArrow:index % 2 reveal:^{}];
            XCTAssertEqual([self addedWindowGestures].firstObject, edge);
            XCTAssertEqual(self.control.gestureRecognizers.firstObject, local);
            XCTAssertTrue(local.enabled);
            [self.control hide];
            XCTAssertFalse(local.enabled);
        }
    }
}
- (void)testWindowRevealUsesTheStartingEdgeAndKeepsThirtyPointThreshold {
    LCDockTestRevealGesture *gesture = [LCDockTestRevealGesture new];
    gesture.windowRoute = YES;
    [self.guest addGestureRecognizer:gesture];
    for (NSNumber *dockRight in @[@NO, @YES]) {
        for (NSNumber *startRight in @[@NO, @YES]) {
            [self showRight:dockRight.boolValue hideArrow:YES];
            CGFloat x = startRight.boolValue ? CGRectGetMaxX(self.window.bounds) - 22 : CGRectGetMinX(self.window.bounds) + 22;
            CGFloat inward = startRight.boolValue ? -1 : 1;
            NSUInteger before = self.reveals;
            LCDockTestTouch *touch = [self beginReveal:gesture at:CGPointMake(x, 100)];
            [self moveReveal:gesture touch:touch to:CGPointMake(x + 4 * inward, 115)];
            XCTAssertEqual(gesture.state, UIGestureRecognizerStatePossible);
            [self moveReveal:gesture touch:touch to:CGPointMake(x + 29 * inward, 108)];
            XCTAssertEqual(self.reveals, before);
            [self moveReveal:gesture touch:touch to:CGPointMake(x + 30 * inward, 108)];
            XCTAssertEqual(self.reveals, before + 1);
            [self.control hide];
        }
    }
    [self.guest removeGestureRecognizer:gesture];
}
- (void)testRevealRejectsVerticalOutwardCancelledAndMultipleFingerGestures {
    LCDockTestRevealGesture *gesture = [LCDockTestRevealGesture new];
    [self.guest addGestureRecognizer:gesture];
    for (NSNumber *windowRoute in @[@NO, @YES]) {
        [self showRight:NO hideArrow:YES];
        gesture.right = NO;
        gesture.windowRoute = windowRoute.boolValue;
        for (NSValue *move in @[[NSValue valueWithCGPoint:CGPointMake(4, 30)],
                                [NSValue valueWithCGPoint:CGPointMake(-16, 0)]]) {
            LCDockTestTouch *touch = [self beginReveal:gesture at:CGPointMake(22, 100)];
            [self moveReveal:gesture touch:touch to:CGPointMake(22 + move.CGPointValue.x, 100 + move.CGPointValue.y)];
            [self moveReveal:gesture touch:touch to:CGPointMake(70, 100)];
            XCTAssertEqual(self.reveals, 0u);
        }
        LCDockTestTouch *touch = [self beginReveal:gesture at:CGPointMake(22, 100)];
        [self moveReveal:gesture touch:touch to:CGPointMake(32, 102)];
        [gesture touchesCancelled:[NSSet setWithObject:touch] withEvent:self.testEvent];
        [self moveReveal:gesture touch:touch to:CGPointMake(70, 100)];
        XCTAssertEqual(self.reveals, 0u);
        touch = [self beginReveal:gesture at:CGPointMake(22, 100)];
        [gesture touchesBegan:[NSSet setWithObject:[LCDockTestTouch new]] withEvent:self.testEvent];
        [self moveReveal:gesture touch:touch to:CGPointMake(70, 100)];
        XCTAssertEqual(gesture.state, UIGestureRecognizerStateFailed);
        XCTAssertEqual(self.reveals, 0u);
        touch = [self beginReveal:gesture at:CGPointMake(22, 100)];
        [self moveReveal:gesture touch:touch to:CGPointMake(32, 102)];
        [gesture touchesBegan:[NSSet setWithObject:[LCDockTestTouch new]] withEvent:self.testEvent];
        [self moveReveal:gesture touch:touch to:CGPointMake(70, 100)];
        XCTAssertEqual(gesture.state, UIGestureRecognizerStateCancelled);
        XCTAssertEqual(self.reveals, 0u);
        [self.control hide];
    }
    [self.guest removeGestureRecognizer:gesture];
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
    XCTAssertTrue([hide gestureRecognizer:hide shouldRecognizeSimultaneouslyWithGestureRecognizer:[UITapGestureRecognizer new]]);
    XCTAssertTrue([hide gestureRecognizer:hide shouldRecognizeSimultaneouslyWithGestureRecognizer:[UILongPressGestureRecognizer new]]);
    XCTAssertTrue(hide.cancelsTouchesInView);
    XCTAssertTrue(hide.delaysTouchesBegan);
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
        XCTAssertEqual(hide.state, UIGestureRecognizerStateChanged);
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
        XCTAssertTrue(hide.state == UIGestureRecognizerStateFailed || hide.state == UIGestureRecognizerStateEnded);
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
    touch = [self beginHide:hide];
    [self moveHide:hide touch:touch by:CGPointMake(7, 1)];
    [hide touchesBegan:[NSSet setWithObject:[LCDockTestTouch new]] withEvent:self.testEvent];
    [self moveHide:hide touch:touch by:CGPointMake(30, 0)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStateCancelled);
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
- (void)testOutwardIntentClaimsBeforeMenuButStillNeedsFullHideDistance {
    LCDockTestHideGesture *hide = [LCDockTestHideGesture new];
    __block NSUInteger hidden = 0;
    [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{ hidden += 1; }];
    LCDockTestTouch *touch = [self beginHide:hide];
    [self moveHide:hide touch:touch by:CGPointMake(2, 1)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStatePossible);
    XCTAssertEqual(hidden, 0u);
    [self moveHide:hide touch:touch by:CGPointMake(3, 1)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStateBegan);
    XCTAssertEqual(hidden, 0u);
    [self moveHide:hide touch:touch by:CGPointMake(9, 2)];
    XCTAssertEqual(hide.state, UIGestureRecognizerStateChanged);
    XCTAssertEqual(hidden, 0u);
    [self moveHide:hide touch:touch by:CGPointMake(16, 3)];
    XCTAssertEqual(hidden, 1u);
    [hide detach];
}
- (void)testPrimaryActionMenuWaitsForSwipeIntentButAccountGesturesDoNot {
    LCDockHideGesture *hide = [LCDockHideGesture new];
    [hide attachToView:self.guest ignoredTopHeight:50 right:YES hide:^{}];
    UIButton *menuButton = [UIButton new];
    menuButton.menu = [UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"Layout" image:nil identifier:nil handler:^(UIAction *action) {}]]];
    menuButton.showsMenuAsPrimaryAction = YES;
    [self.guest addSubview:menuButton];
    UIGestureRecognizer *menuGesture = [UIGestureRecognizer new];
    [menuButton addGestureRecognizer:menuGesture];
    XCTAssertTrue([hide gestureRecognizer:hide shouldBeRequiredToFailByGestureRecognizer:menuGesture]);
    menuButton.showsMenuAsPrimaryAction = NO;
    XCTAssertFalse([hide gestureRecognizer:hide shouldBeRequiredToFailByGestureRecognizer:menuGesture]);
    menuButton.showsMenuAsPrimaryAction = YES;
    menuButton.menu = nil;
    XCTAssertFalse([hide gestureRecognizer:hide shouldBeRequiredToFailByGestureRecognizer:menuGesture]);
    menuButton.menu = [UIMenu menuWithChildren:@[]];
    [self.window addSubview:menuButton];
    XCTAssertFalse([hide gestureRecognizer:hide shouldBeRequiredToFailByGestureRecognizer:menuGesture]);
    [menuButton removeFromSuperview];
    UILongPressGestureRecognizer *accountPress = [UILongPressGestureRecognizer new];
    [self.guest addGestureRecognizer:accountPress];
    XCTAssertFalse([hide gestureRecognizer:hide shouldBeRequiredToFailByGestureRecognizer:accountPress]);
    [self.guest removeGestureRecognizer:accountPress];
    [hide detach];
}
@end
