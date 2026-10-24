#import <XCTest/XCTest.h>

@interface DockGestureUITests : XCTestCase
@property(nonatomic) XCUIApplication *app;
@end

@implementation DockGestureUITests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.livecontainer.tests.dock-gestures"];
}
- (void)tearDown {
    [self.app terminate];
    self.app = nil;
    [super tearDown];
}
- (void)launchRight:(BOOL)right narrow:(BOOL)narrow {
    [self launchRight:right narrow:narrow hiddenArrow:NO restored:NO];
}
- (void)launchRight:(BOOL)right narrow:(BOOL)narrow hiddenArrow:(BOOL)hiddenArrow restored:(BOOL)restored {
    self.app.launchArguments = @[(right ? @"--right" : @"--left"), (narrow ? @"--narrow" : @"--default"),
        (hiddenArrow ? @"--hide-arrow" : @"--show-arrow"), (restored ? @"--restore-four" : @"--one-guest")];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"DockAccount0"] waitForExistenceWithTimeout:5]);
}
- (void)waitForStatus:(NSString *)status {
    if ([status isEqualToString:@"hidden"] && ![self.app.staticTexts[@"DockStatus"].label isEqualToString:status]) {
        NSLog(@"Dock hide gesture trace: %@", self.app.staticTexts[@"DockGestureTrace"].label);
    }
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label == %@", status];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:self.app.staticTexts[@"DockStatus"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:5], XCTWaiterResultCompleted);
}
- (void)hideDock {
    [self.app.buttons[@"HideDock"] tap];
    [self waitForStatus:@"hidden"];
    XCTAssertTrue([self.app.buttons[@"LCDockRevealControl"] waitForExistenceWithTimeout:3]);
}
- (void)dragFromEdgeRight:(BOOL)right inset:(CGFloat)inset fraction:(CGFloat)fraction dx:(CGFloat)dx dy:(CGFloat)dy {
    XCUIElement *window = self.app.windows.firstMatch;
    CGRect frame = window.frame;
    CGFloat x = right ? CGRectGetWidth(frame) - inset : inset;
    XCUICoordinate *start = [[window coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
        coordinateWithOffset:CGVectorMake(x, CGRectGetHeight(frame) * fraction)];
    XCUICoordinate *end = [start coordinateWithOffset:CGVectorMake(dx, dy)];
    [start pressForDuration:0.05 thenDragToCoordinate:end withVelocity:120 thenHoldForDuration:0];
}
- (void)dragElement:(XCUIElement *)element dx:(CGFloat)dx dy:(CGFloat)dy hold:(NSTimeInterval)hold {
    XCUICoordinate *start = [element coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
    XCUICoordinate *end = [start coordinateWithOffset:CGVectorMake(dx, dy)];
    [start pressForDuration:0.05 thenDragToCoordinate:end withVelocity:60 thenHoldForDuration:hold];
}
- (void)testShortAccountSwipesHideOnBothEdgesAndWidthsBeforeLift {
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *narrow in @[@NO, @YES]) {
            [self launchRight:right.boolValue narrow:narrow.boolValue];
            [self dragElement:self.app.buttons[@"DockAccount0"] dx:(right.boolValue ? 22 : -22) dy:8 hold:1];
            [self waitForStatus:@"hidden"];
            XCTAssertEqualObjects(self.app.staticTexts[@"DockHiddenDuringTouch"].label, @"yes");
            XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
            [self.app.buttons[@"ShowDock"] tap];
            [self waitForStatus:@"visible"];
            [self dragElement:self.app.buttons[@"DockCollapse"] dx:(right.boolValue ? 22 : -22) dy:4 hold:0];
            [self waitForStatus:@"hidden"];
            [self.app terminate];
        }
    }
}
- (void)testAccountScrollingAndHandleMovementDoNotHide {
    [self launchRight:YES narrow:NO];
    [self dragElement:self.app.buttons[@"DockAccount1"] dx:5 dy:-110 hold:0];
    XCTAssertTrue(self.app.buttons[@"DockAccount3"].hittable);
    [self waitForStatus:@"visible"];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
    [self dragElement:self.app.images[@"DockHandle"] dx:22 dy:0 hold:0];
    [self waitForStatus:@"visible"];
    XCTAssertGreaterThan(self.app.staticTexts[@"DockHandleMoves"].label.integerValue, 0);
}
- (void)testAccountTapSmallDriftAndContextMenuRemainUsable {
    [self launchRight:NO narrow:YES];
    [self.app.buttons[@"DockAccount0"] tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"1");
    [self dragElement:self.app.buttons[@"DockAccount0"] dx:-8 dy:0 hold:0];
    [self waitForStatus:@"visible"];
    [self.app.buttons[@"DockAccount0"] pressForDuration:1];
    XCUIElement *action = self.app.buttons[@"Window action"];
    XCTAssertTrue([action waitForExistenceWithTimeout:3]);
    [action tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockContextActions"].label, @"1");
    [self waitForStatus:@"visible"];
}
- (void)testOutwardSwipeAlsoWorksOnMenuButton {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:YES];
        NSLog(@"DockMenu frame: %@", NSStringFromCGRect(self.app.buttons[@"DockMenu"].frame));
        [self dragElement:self.app.buttons[@"DockMenu"] dx:(right.boolValue ? 22 : -22) dy:4 hold:0];
        if (![self.app.staticTexts[@"DockStatus"].label isEqualToString:@"hidden"]) {
            NSLog(@"Menu gesture trace: %@", self.app.staticTexts[@"DockGestureTrace"].label);
            NSLog(@"Menu swipe hierarchy: %@", self.app.debugDescription);
        }
        [self waitForStatus:@"hidden"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
        [self.app.buttons[@"ShowDock"] tap];
        [self waitForStatus:@"visible"];
        [self.app.buttons[@"DockMenu"] tap];
        XCUIElement *layout = self.app.buttons[@"Layout"];
        XCTAssertTrue([layout waitForExistenceWithTimeout:3]);
        [layout tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockContextActions"].label, @"1");
        [self waitForStatus:@"visible"];
        [self.app terminate];
    }
}
- (void)testNativeTabTapAndInwardDragAfterRestoringFourGuests {
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *hiddenArrow in @[@NO, @YES]) {
            [self launchRight:right.boolValue narrow:NO hiddenArrow:hiddenArrow.boolValue restored:YES];
            XCTAssertEqualObjects(self.app.staticTexts[@"GuestCount"].label, @"4");
            [self hideDock];
            [self.app.buttons[@"LCDockRevealControl"] tap];
            [self waitForStatus:@"visible"];
            [self hideDock];
            [self dragElement:self.app.buttons[@"LCDockRevealControl"] dx:(right.boolValue ? -60 : 60) dy:5 hold:0];
            [self waitForStatus:@"visible"];
            XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"2");
            XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
            [self.app terminate];
        }
    }
}
- (void)testHiddenEdgeSwipeNearEdgeSurvivesWorkspaceRestoreAndRepeatedHiding {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:YES hiddenArrow:YES restored:NO];
        [self hideDock];
        [self.app.buttons[@"RestoreWorkspace"] tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestCount"].label, @"4");
        for (NSUInteger index = 0; index < 2; ++index) {
            // A finger can begin inside the 44pt edge band, well above the
            // remembered tab. This is distinct from dragging the small tab.
            [self dragFromEdgeRight:right.boolValue inset:22 fraction:0.25 dx:(right.boolValue ? -80 : 80) dy:4];
            [self waitForStatus:@"visible"];
            XCTAssertEqual(self.app.staticTexts[@"DockReveals"].label.integerValue, index + 1);
            [self hideDock];
        }
        [self.app terminate];
    }
}
- (void)testPhysicalEdgeSwipeWithVisibleArrowAndFourGuests {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:NO hiddenArrow:NO restored:YES];
        [self hideDock];
        [self dragFromEdgeRight:right.boolValue inset:2 fraction:0.25 dx:(right.boolValue ? -80 : 80) dy:4];
        [self waitForStatus:@"visible"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"1");
        [self.app terminate];
    }
}
- (void)testHiddenEdgeDoesNotBlockGuestTapsScrollingOrInteriorDrags {
    [self launchRight:YES narrow:NO hiddenArrow:YES restored:YES];
    [self hideDock];
    // A touch away from the remembered tab still reaches its guest; an edge
    // pan must not reserve a full-height transparent overlay or cancel it.
    XCUIElement *window = self.app.windows.firstMatch;
    XCUICoordinate *edge = [[window coordinateWithNormalizedOffset:CGVectorMake(1, 0.25)]
        coordinateWithOffset:CGVectorMake(-22, 0)];
    [edge tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"GuestTaps"].label, @"1");
    [self dragFromEdgeRight:YES inset:22 fraction:0.25 dx:3 dy:100];
    [self waitForStatus:@"hidden"];
    XCTAssertGreaterThan(self.app.staticTexts[@"GuestDrags"].label.integerValue, 0);
    [self dragFromEdgeRight:YES inset:100 fraction:0.25 dx:-80 dy:0];
    [self waitForStatus:@"hidden"];
    [self dragElement:self.app.buttons[@"LCDockRevealControl"] dx:-10 dy:1 hold:0];
    [self waitForStatus:@"hidden"];
}
@end
