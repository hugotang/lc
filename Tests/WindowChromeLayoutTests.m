#import <XCTest/XCTest.h>
#import "../MultitaskSupport/WindowChromeLayout.h"
#import "TapSyncTestWindow.h"

@interface WindowChromeLayoutTests : XCTestCase
@property(nonatomic) UIViewController *controller;
@property(nonatomic) UIStackView *container;
@property(nonatomic) UIView *guest;
@property(nonatomic) UINavigationBar *bar;
@property(nonatomic) LCWindowChromeLayout *chrome;
@end

@implementation WindowChromeLayoutTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    UIViewController *root = LCTapSyncTestHostWindow().rootViewController;
    XCTAssertNotNil(root);
    self.controller = [UIViewController new];
    self.container = [[UIStackView alloc] initWithFrame:CGRectMake(40, 60, 400, 600)];
    self.container.axis = UILayoutConstraintAxisVertical;
    self.controller.view = self.container;
    self.controller.additionalSafeAreaInsets = UIEdgeInsetsMake(24, 12, 20, 16);
    [root addChildViewController:self.controller];
    [root.view addSubview:self.container];
    [self.controller didMoveToParentViewController:root];
    // Production has a non-interactive arranged placeholder behind the real guest.
    UIView *placeholder = [UIView new];
    placeholder.userInteractionEnabled = NO;
    [self.container addArrangedSubview:placeholder];
    self.guest = [UIView new];
    self.guest.backgroundColor = UIColor.systemBlueColor;
    [self.container insertSubview:self.guest atIndex:0];
    self.bar = [UINavigationBar new];
    self.bar.items = @[[[UINavigationItem alloc] initWithTitle:@"#2 · Account"]];
    self.chrome = [LCWindowChromeLayout new];
}
- (void)tearDown {
    [self.controller willMoveToParentViewController:nil];
    [self.container removeFromSuperview];
    [self.controller removeFromParentViewController];
    self.chrome = nil;
    self.controller = nil;
    self.container = nil;
    self.guest = nil;
    self.bar = nil;
    [super tearDown];
}
- (BOOL)applyOverlay:(BOOL)overlay bottom:(BOOL)bottom hidden:(BOOL)hidden {
    BOOL changed = [self.chrome applyToContainer:self.container guest:self.guest bar:self.bar
                                          bottom:bottom hidden:hidden overlay:overlay];
    [self.container setNeedsLayout];
    [self.container layoutIfNeeded];
    return changed;
}
- (NSArray<NSLayoutConstraint *> *)guestConstraints {
    NSMutableArray *result = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in self.container.constraints) {
        if (constraint.active && (constraint.firstItem == self.guest || constraint.secondItem == self.guest)) [result addObject:constraint];
    }
    return result.copy;
}
- (void)testOverlayVisibilityKeepsGuestGeometryAndConstraints {
    XCTAssertTrue([self applyOverlay:YES bottom:NO hidden:NO]);
    CGRect guest = self.guest.frame;
    UIEdgeInsets insets = self.guest.safeAreaInsets;
    NSArray *constraints = [self guestConstraints];
    XCTAssertTrue(CGRectEqualToRect(guest, self.container.bounds));
    for (NSUInteger index = 0; index < 20; index++) {
        BOOL hidden = index % 2 == 0;
        XCTAssertFalse([self applyOverlay:YES bottom:NO hidden:hidden]);
        XCTAssertTrue(CGRectEqualToRect(self.guest.frame, guest));
        XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(self.guest.safeAreaInsets, insets));
        XCTAssertEqualObjects([self guestConstraints], constraints);
        XCTAssertEqual(self.bar.hidden, hidden);
        XCTAssertEqual(self.bar.userInteractionEnabled, !hidden);
    }
}
- (void)testOverlayTopBottomMovesOnlyTheBarWithoutLeakingAnchors {
    [self applyOverlay:YES bottom:NO hidden:NO];
    CGRect guest = self.guest.frame;
    NSArray *constraints = [self guestConstraints];
    NSUInteger count = self.container.constraints.count;
    for (NSUInteger index = 0; index < 20; index++) {
        BOOL bottom = index % 2 == 0;
        XCTAssertFalse([self applyOverlay:YES bottom:bottom hidden:NO]);
        CGRect safe = self.container.safeAreaLayoutGuide.layoutFrame;
        XCTAssertEqualWithAccuracy(self.bar.frame.origin.x, safe.origin.x, 0.01);
        XCTAssertEqualWithAccuracy(self.bar.frame.size.width, safe.size.width, 0.01);
        XCTAssertEqualWithAccuracy(self.bar.frame.size.height, 44, 0.01);
        XCTAssertEqualWithAccuracy(bottom ? CGRectGetMaxY(self.bar.frame) : CGRectGetMinY(self.bar.frame),
                                  bottom ? CGRectGetMaxY(safe) : CGRectGetMinY(safe), 0.01);
        XCTAssertTrue(CGRectEqualToRect(self.guest.frame, guest));
        XCTAssertEqualObjects([self guestConstraints], constraints);
        XCTAssertEqual(self.container.constraints.count, count);
    }
    XCTAssertTrue([self applyOverlay:NO bottom:NO hidden:NO]);
    XCTAssertEqualWithAccuracy(self.guest.frame.origin.y, 44, 0.01);
}
- (void)testOverlayGuestTracksRotationAndKeyboardSizedHost {
    [self applyOverlay:YES bottom:NO hidden:NO];
    for (NSValue *value in @[[NSValue valueWithCGRect:CGRectMake(40, 60, 700, 300)],
                            [NSValue valueWithCGRect:CGRectMake(40, 60, 400, 260)]]) {
        self.container.frame = value.CGRectValue;
        XCTAssertFalse([self applyOverlay:YES bottom:NO hidden:NO]);
        XCTAssertTrue(CGRectEqualToRect(self.guest.frame, self.container.bounds));
        CGRect beforeHide = self.guest.frame;
        XCTAssertFalse([self applyOverlay:YES bottom:NO hidden:YES]);
        XCTAssertTrue(CGRectEqualToRect(self.guest.frame, beforeHide));
    }
}
- (void)testReturningToNormalLayoutReservesOneBarRow {
    [self applyOverlay:YES bottom:NO hidden:NO];
    for (NSNumber *bottom in @[@NO, @YES]) {
        [self applyOverlay:NO bottom:bottom.boolValue hidden:NO];
        XCTAssertEqualWithAccuracy(self.guest.frame.size.height, self.container.bounds.size.height - 44, 0.01);
        XCTAssertEqualWithAccuracy(self.guest.frame.origin.y, bottom.boolValue ? 0 : 44, 0.01);
        XCTAssertTrue([self.container.arrangedSubviews containsObject:self.bar]);
        XCTAssertTrue([self applyOverlay:NO bottom:bottom.boolValue hidden:YES]);
        XCTAssertTrue(CGRectEqualToRect(self.guest.frame, self.container.bounds));
        [self applyOverlay:YES bottom:bottom.boolValue hidden:NO];
        XCTAssertFalse([self.container.arrangedSubviews containsObject:self.bar]);
    }
}
- (void)testHiddenGridBarCanRestoreTerminatedWindowControls {
    [self applyOverlay:YES bottom:NO hidden:YES];
    XCTAssertTrue([self applyOverlay:NO bottom:NO hidden:YES]);
    XCTAssertTrue(CGRectEqualToRect(self.guest.frame, self.container.bounds));
    XCTAssertTrue([self applyOverlay:NO bottom:NO hidden:NO]);
    XCTAssertFalse(self.bar.hidden);
    XCTAssertTrue(self.bar.userInteractionEnabled);
    XCTAssertEqualWithAccuracy(self.guest.frame.size.height, self.container.bounds.size.height - 44, 0.01);
}
- (void)testOverlayControlsReceiveTouchesAndUncoveredSpaceReachesGuest {
    [self applyOverlay:YES bottom:NO hidden:NO];
    CGPoint control = self.bar.center;
    UIView *hit = [self.container hitTest:control withEvent:nil];
    XCTAssertTrue(hit == self.bar || [hit isDescendantOfView:self.bar]);
    XCTAssertEqual([self.container hitTest:CGPointMake(200, 350) withEvent:nil], self.guest);
    [self applyOverlay:YES bottom:NO hidden:YES];
    XCTAssertEqual([self.container hitTest:control withEvent:nil], self.guest);
}
- (void)testOverlayKeepsScaledGuestContentAndUnrelatedGestures {
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    content.transform = CGAffineTransformMakeScale(2, 2);
    [self.guest addSubview:content];
    UITapGestureRecognizer *gesture = [UITapGestureRecognizer new];
    [self.container addGestureRecognizer:gesture];
    [self applyOverlay:YES bottom:YES hidden:NO];
    [self applyOverlay:YES bottom:YES hidden:YES];
    XCTAssertTrue(CGAffineTransformEqualToTransform(content.transform, CGAffineTransformMakeScale(2, 2)));
    XCTAssertTrue([self.container.gestureRecognizers containsObject:gesture]);
}
@end
