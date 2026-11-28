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
    // Accessibility snapshots can take several seconds on a busy CI simulator.
    // Wait for the same state without repeating the gesture or relaxing it.
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[expectation] timeout:15];
    if (result != XCTWaiterResultCompleted) {
        NSLog(@"Reveal trace: %@", self.app.staticTexts[@"DockRevealTrace"].label);
        NSLog(@"Actual Dock status: %@", self.app.staticTexts[@"DockStatus"].label);
    }
    XCTAssertEqual(result, XCTWaiterResultCompleted);
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
    // Resolve the element before touching. Repeated element-relative coordinate
    // lookups during synthesis can turn a short drag into a context-menu hold.
    XCUIElement *window = self.app.windows.firstMatch;
    CGRect windowFrame = window.frame;
    CGRect elementFrame = element.frame;
    XCUICoordinate *start = [[window coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
        coordinateWithOffset:CGVectorMake(CGRectGetMidX(elementFrame) - CGRectGetMinX(windowFrame),
                                         CGRectGetMidY(elementFrame) - CGRectGetMinY(windowFrame))];
    XCUICoordinate *end = [start coordinateWithOffset:CGVectorMake(dx, dy)];
    [start pressForDuration:0.01 thenDragToCoordinate:end withVelocity:300 thenHoldForDuration:hold];
}
- (void)dragNearTabRight:(BOOL)right inwardOffset:(CGFloat)inwardOffset verticalOffset:(CGFloat)verticalOffset
                distance:(CGFloat)distance dy:(CGFloat)dy velocity:(CGFloat)velocity {
    XCUIElement *window = self.app.windows.firstMatch;
    CGRect windowFrame = window.frame;
    CGRect tabFrame = self.app.buttons[@"LCDockRevealControl"].frame;
    XCUICoordinate *start = [[window coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
        coordinateWithOffset:CGVectorMake(CGRectGetMidX(tabFrame) - CGRectGetMinX(windowFrame) +
                                         (right ? -inwardOffset : inwardOffset),
                                         CGRectGetMidY(tabFrame) - CGRectGetMinY(windowFrame) + verticalOffset)];
    XCUICoordinate *end = [start coordinateWithOffset:CGVectorMake(right ? -distance : distance, dy)];
    [start pressForDuration:0.01 thenDragToCoordinate:end withVelocity:velocity thenHoldForDuration:0];
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
    [self waitForStatus:@"visible"];
    NSPredicate *hittable = [NSPredicate predicateWithFormat:@"hittable == YES"];
    XCTNSPredicateExpectation *scrolled = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:hittable object:self.app.buttons[@"DockAccount3"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[scrolled] timeout:15], XCTWaiterResultCompleted);
    XCTAssertFalse(self.app.buttons[@"Window action"].exists);
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
    XCTAssertFalse(self.app.buttons[@"Window action"].exists);
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
- (void)testShortNearArrowSwipesRevealOnFirstAttempt {
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *hiddenArrow in @[@NO, @YES]) {
            [self launchRight:right.boolValue narrow:YES hiddenArrow:hiddenArrow.boolValue restored:YES];
            // Cover the original center, a finger landing above/below the
            // invisible arrow, and a start a few points inside its old frame.
            for (NSValue *offset in @[[NSValue valueWithCGPoint:CGPointZero],
                                      [NSValue valueWithCGPoint:CGPointMake(0, -40)],
                                      [NSValue valueWithCGPoint:CGPointMake(0, 40)],
                                      [NSValue valueWithCGPoint:CGPointMake(28, 0)]]) {
                [self hideDock];
                CGPoint point = offset.CGPointValue;
                [self dragNearTabRight:right.boolValue inwardOffset:point.x verticalOffset:point.y
                             distance:22 dy:8 velocity:200];
                [self waitForStatus:@"visible"];
            }
            XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"4");
            XCTAssertEqualObjects(self.app.staticTexts[@"GuestTaps"].label, @"0");
            XCTAssertEqualObjects(self.app.staticTexts[@"GuestDrags"].label, @"0");
            [self.app terminate];
        }
    }
}
- (void)testRepeatedQuickDiagonalTabSwipesDoNotNeedALongPull {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:NO hiddenArrow:YES restored:YES];
        [self hideDock];
        [self.app.buttons[@"RestoreWorkspace"] tap];
        for (NSUInteger index = 0; index < 5; ++index) {
            [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:0
                         distance:24 dy:(index % 2 ? -14 : 14) velocity:(index % 2 ? 500 : 100)];
            [self waitForStatus:@"visible"];
            XCTAssertEqual(self.app.staticTexts[@"DockReveals"].label.integerValue, index + 1);
            [self hideDock];
        }
        [self.app terminate];
    }
}
- (void)testOppositeEdgeRetainsTheOriginalInwardReveal {
    for (NSNumber *dockRight in @[@NO, @YES]) {
        [self launchRight:dockRight.boolValue narrow:NO hiddenArrow:YES restored:YES];
        [self hideDock];
        BOOL startRight = !dockRight.boolValue;
        [self dragFromEdgeRight:startRight inset:22 fraction:0.25 dx:(startRight ? -50 : 50) dy:8];
        [self waitForStatus:@"visible"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"1");
        [self.app terminate];
    }
}
- (void)launchWebGuestsRight:(BOOL)right {
    self.app.launchArguments = @[(right ? @"--right" : @"--left"), @"--hide-arrow", @"--restore-four", @"--web-guests"];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"DockAccount0"] waitForExistenceWithTimeout:5]);
    NSPredicate *ready = [NSPredicate predicateWithFormat:@"label == '4'"];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:ready object:self.app.staticTexts[@"WebGuestsReady"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:15], XCTWaiterResultCompleted);
}
- (void)testHiddenArrowRecoveryAboveFourWebGuestsAndAfterMinimize {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchWebGuestsRight:right.boolValue];
        // Establish that the WebKit guest actually receives external-content
        // input away from the local Dock patch, rather than testing blank views.
        XCUIElement *window = self.app.windows.firstMatch;
        XCUICoordinate *guest = [[window coordinateWithNormalizedOffset:CGVectorMake(1, 0.25)]
            coordinateWithOffset:CGVectorMake(-22, 0)];
        [guest tap];
        XCTNSPredicateExpectation *tap = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithFormat:@"label == '1'"] object:self.app.staticTexts[@"GuestTaps"]];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[tap] timeout:5], XCTWaiterResultCompleted);
        [self hideDock];
        [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:0 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        [self.app.buttons[@"MinimizeGuests"] tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestVisibility"].label, @"minimized");
        [self hideDock];
        [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:0 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        [self.app.buttons[@"RestoreGuests"] tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestVisibility"].label, @"running");
        [self hideDock];
        [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:40 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"3");
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestTaps"].label, @"1");
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestDrags"].label, @"0");
        [self.app terminate];
    }
}
- (void)testArrowVisibilityToggleRetainsRecoveryAboveFourWebGuests {
    [self launchWebGuestsRight:YES];
    [self hideDock];
    for (NSUInteger index = 0; index < 3; ++index) {
        XCTAssertEqualObjects(self.app.staticTexts[@"ArrowVisibility"].label, @"hidden");
        [self.app.buttons[@"ToggleArrow"] tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"ArrowVisibility"].label, @"visible");
        [self dragNearTabRight:YES inwardOffset:0 verticalOffset:0 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        [self hideDock];
        [self.app.buttons[@"ToggleArrow"] tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"ArrowVisibility"].label, @"hidden");
        [self dragNearTabRight:YES inwardOffset:0 verticalOffset:0 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        [self hideDock];
    }
    XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"6");
    XCTAssertEqualObjects(self.app.staticTexts[@"GuestTaps"].label, @"0");
    XCTAssertEqualObjects(self.app.staticTexts[@"GuestDrags"].label, @"0");
}
- (void)testSwipeOnlyHiddenArrowIgnoresTapsAndRevealsAboveFourWebGuests {
    for (NSNumber *right in @[@NO, @YES]) {
        self.app.launchArguments = @[(right.boolValue ? @"--right" : @"--left"), @"--hide-arrow",
            @"--swipe-only", @"--restore-four", @"--web-guests"];
        [self.app launch];
        XCTAssertTrue([self.app.buttons[@"DockAccount0"] waitForExistenceWithTimeout:5]);
        XCTNSPredicateExpectation *ready = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithFormat:@"label == '4'"] object:self.app.staticTexts[@"WebGuestsReady"]];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[ready] timeout:15], XCTWaiterResultCompleted);
        [self hideDock];
        for (NSUInteger index = 0; index < 3; index++) {
            [self.app.buttons[@"LCDockRevealControl"] tap];
            [self waitForStatus:@"hidden"];
        }
        XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"0");
        [self.app.buttons[@"RestoreWorkspace"] tap];
        [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:0 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        [self hideDock];
        [self.app.buttons[@"ToggleArrow"] tap];
        [self.app.buttons[@"LCDockRevealControl"] tap];
        [self waitForStatus:@"visible"];
        [self hideDock];
        [self.app.buttons[@"ToggleArrow"] tap];
        [self.app.buttons[@"LCDockRevealControl"] tap];
        [self waitForStatus:@"hidden"];
        [self dragNearTabRight:right.boolValue inwardOffset:0 verticalOffset:40 distance:22 dy:5 velocity:200];
        [self waitForStatus:@"visible"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockReveals"].label, @"3");
        XCTAssertEqualObjects(self.app.staticTexts[@"GuestTaps"].label, @"0");
        [self.app terminate];
    }
}
@end
