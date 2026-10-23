#import <XCTest/XCTest.h>
#import "../MultitaskSupport/DockRevealControl.h"
#import "TapSyncTestWindow.h"

@interface LCDockRevealControl (Testing)
- (void)handleRevealPan:(UIPanGestureRecognizer *)gesture;
@end

@interface LCDockTestPan : UIPanGestureRecognizer
@property(nonatomic) CGPoint testTranslation;
@property(nonatomic) UIGestureRecognizerState testState;
@end
@implementation LCDockTestPan
- (CGPoint)translationInView:(UIView *)view { return self.testTranslation; }
- (UIGestureRecognizerState)state { return self.testState; }
@end

@interface DockRevealControlTests : XCTestCase
@property(nonatomic) UIWindow *window;
@property(nonatomic) UIView *guest;
@property(nonatomic) LCDockRevealControl *control;
@property(nonatomic) NSUInteger reveals;
@property(nonatomic) NSSet<UIGestureRecognizer *> *originalGestures;
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
}
- (void)tearDown {
    [self.control hide];
    [self.guest removeFromSuperview];
    XCTAssertEqualObjects([NSSet setWithArray:self.window.gestureRecognizers ?: @[]], self.originalGestures);
    self.control = nil;
    self.guest = nil;
    self.window = nil;
    [super tearDown];
}
- (CGRect)frameForRight:(BOOL)right {
    UIEdgeInsets insets = self.window.safeAreaInsets;
    return CGRectMake(right ? CGRectGetMaxX(self.window.bounds) - insets.right - 44 : insets.left,
                      CGRectGetMidY(self.window.bounds) - 22, 44, 44);
}
- (void)showRight:(BOOL)right dimmed:(BOOL)dimmed {
    __weak typeof(self) weakSelf = self;
    [self.control showInWindow:self.window frame:[self frameForRight:right] right:right dimmed:dimmed reveal:^{
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
- (void)testDimmedTabRetainsEntireNativeTouchTargetOnBothEdges {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue dimmed:YES];
        XCTAssertTrue(CGRectContainsRect(self.window.bounds, self.control.frame));
        XCTAssertEqualWithAccuracy(self.control.alpha, 1, 0.001);
        UIView *artwork = self.control.subviews.firstObject;
        XCTAssertTrue(artwork.alpha >= 0.25 && artwork.alpha < 1);
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
    [self showRight:YES dimmed:NO];
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame))
                            withEvent:nil], self.control);
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.window.bounds), CGRectGetMidY(self.window.bounds))
                            withEvent:nil], self.guest);
    // A scene/window can be raised while the Dock is hidden. Refresh reclaims
    // only the small control; it does not install a covering UIWindow.
    [self.window bringSubviewToFront:self.guest];
    [self showRight:YES dimmed:NO];
    XCTAssertEqual([self.window hitTest:CGPointMake(CGRectGetMidX(self.control.frame), CGRectGetMidY(self.control.frame))
                            withEvent:nil], self.control);
    XCTAssertEqual(self.control.window, self.window);
}
- (void)testTapAndVoiceOverRevealOnceThenRearmAfterHide {
    [self showRight:YES dimmed:NO];
    [self.control sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertTrue([self.control accessibilityActivate]);
    XCTAssertEqual(self.reveals, 1u);
    [self.control hide];
    XCTAssertFalse([self.control accessibilityActivate]);
    [self showRight:NO dimmed:NO];
    XCTAssertTrue([self.control accessibilityActivate]);
    XCTAssertEqual(self.reveals, 2u);
}
- (void)testInwardDragsRevealFromEitherSideAndIgnoreOutwardOrVerticalDrags {
    for (NSNumber *right in @[@NO, @YES]) {
        [self showRight:right.boolValue dimmed:NO];
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
    [self showRight:YES dimmed:NO];
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
        [self showRight:right dimmed:index % 3 == 0];
        [self showRight:right dimmed:NO];
        NSArray *edges = [self addedWindowGestures];
        XCTAssertEqual(edges.count, 1u);
        XCTAssertEqual(((UIScreenEdgePanGestureRecognizer *)edges.firstObject).edges, right ? UIRectEdgeRight : UIRectEdgeLeft);
        [self.control hide];
        XCTAssertEqual([self addedWindowGestures].count, 0u);
        XCTAssertNil(self.control.superview);
    }
}
- (void)testMovingControlToAnotherHostRemovesTheOldEdgeRecognizer {
    [self showRight:YES dimmed:NO];
    UIWindow *other = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    UIGestureRecognizer *unrelated = [UITapGestureRecognizer new];
    [other addGestureRecognizer:unrelated];
    [self.control showInWindow:other frame:CGRectMake(0, 400, 44, 44) right:NO dimmed:NO reveal:^{}];
    XCTAssertEqual([self addedWindowGestures].count, 0u);
    XCTAssertEqual(self.control.superview, other);
    XCTAssertTrue([other.gestureRecognizers containsObject:unrelated]);
    [self.control hide];
    XCTAssertEqualObjects(other.gestureRecognizers, @[unrelated]);
}
@end
