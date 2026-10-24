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
- (void)launchRight:(BOOL)right narrow:(BOOL)narrow options:(NSArray<NSString *> *)options {
    self.app.launchArguments = [@[(right ? @"--right" : @"--left"), (narrow ? @"--narrow" : @"--default")]
        arrayByAddingObjectsFromArray:options];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"DockCollapse"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(self.app.images[@"DockHandle"].exists);
}
- (void)waitForStatus:(NSString *)status {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label == %@", status];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:self.app.staticTexts[@"DockStatus"]];
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[expectation] timeout:5];
    if (result != XCTWaiterResultCompleted) {
        NSLog(@"Dock drag trace: %@", self.app.staticTexts[@"DockGestureTrace"].label);
        NSLog(@"Dock hierarchy: %@", self.app.debugDescription);
    }
    XCTAssertEqual(result, XCTWaiterResultCompleted);
}
- (void)dragElement:(XCUIElement *)element dx:(CGFloat)dx dy:(CGFloat)dy velocity:(CGFloat)velocity {
    XCUICoordinate *start = [element coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
    [start pressForDuration:0.05 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(dx, dy)]
              withVelocity:velocity thenHoldForDuration:0];
}
- (void)testWholeDockShortOutwardReleaseHidesOnBothEdgesAndWidths {
    for (NSNumber *right in @[@NO, @YES]) {
        for (NSNumber *narrow in @[@NO, @YES]) {
            [self launchRight:right.boolValue narrow:narrow.boolValue options:@[]];
            [self dragElement:self.app.buttons[@"DockAccount0"] dx:(right.boolValue ? 18 : -18) dy:5 velocity:600];
            [self waitForStatus:@"hidden"];
            XCTAssertEqualObjects(self.app.staticTexts[@"DockHiddenDuringTouch"].label, @"no");
            XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
            [self.app.buttons[@"ShowDock"] tap];
            [self waitForStatus:@"visible"];
            [self dragElement:self.app.buttons[@"DockCollapse"] dx:(right.boolValue ? 18 : -18) dy:3 velocity:60];
            [self waitForStatus:@"hidden"];
            XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
            [self.app terminate];
        }
    }
}
- (void)testVerticalBackgroundDragMovesAndInwardDragCanSwitchEdge {
    [self launchRight:YES narrow:NO options:@[]];
    XCUIElement *dock = self.app.otherElements[@"DockBody"].firstMatch;
    XCTAssertTrue(dock.exists);
    XCUICoordinate *start = [dock coordinateWithNormalizedOffset:CGVectorMake(0.04, 0.5)];
    [start pressForDuration:0.05 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(2, -90)]
              withVelocity:300 thenHoldForDuration:0];
    [self waitForStatus:@"visible"];
    XCTAssertGreaterThan(self.app.staticTexts[@"DockMoves"].label.integerValue, 0);
    XCTAssertLessThan(self.app.staticTexts[@"DockFraction"].label.doubleValue, 0.5);
    CGFloat distance = -self.app.windows.firstMatch.frame.size.width * 0.75;
    [self dragElement:self.app.buttons[@"DockCollapse"] dx:distance dy:0 velocity:600];
    [self waitForStatus:@"visible"];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockSide"].label, @"left");
}
- (void)testAccountScrollingStaysLocal {
    [self launchRight:YES narrow:NO options:@[@"--scrollable"]];
    [self dragElement:self.app.buttons[@"DockAccount1"] dx:2 dy:-220 velocity:300];
    [self waitForStatus:@"visible"];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
    XCTAssertEqualObjects(self.app.staticTexts[@"DockMoves"].label, @"0");
    XCTAssertEqualObjects(self.app.staticTexts[@"DockFraction"].label, @"0.5");
    XCTAssertFalse(self.app.buttons[@"DockAccount0"].hittable);
}
- (void)testAccountTapsTinyDriftAndContextMenuRemainUsable {
    [self launchRight:NO narrow:YES options:@[]];
    [self.app.buttons[@"DockAccount0"] tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"1");
    [self dragElement:self.app.buttons[@"DockAccount0"] dx:-2 dy:0 velocity:60];
    [self waitForStatus:@"visible"];
    [self.app.buttons[@"DockAccount0"] pressForDuration:1];
    XCUIElement *action = self.app.buttons[@"Window action"];
    XCTAssertTrue([action waitForExistenceWithTimeout:3]);
    [action tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockContextActions"].label, @"1");
    [self waitForStatus:@"visible"];
}
- (void)testMenuTapActionsAndOutwardDrag {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:YES options:@[]];
        [self.app.buttons[@"DockMenu"] tap];
        XCUIElement *layout = self.app.buttons[@"Layout"];
        XCTAssertTrue([layout waitForExistenceWithTimeout:3]);
        [layout tap];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockContextActions"].label, @"1");
        [self dragElement:self.app.buttons[@"DockMenu"] dx:(right.boolValue ? 18 : -18) dy:3 velocity:300];
        [self waitForStatus:@"hidden"];
        [self.app terminate];
    }
}
- (void)testCollapsedDockOutwardReleaseWithoutMovementHandle {
    for (NSNumber *right in @[@NO, @YES]) {
        [self launchRight:right.boolValue narrow:YES options:@[@"--collapsed"]];
        [self.app.buttons[@"DockCollapse"] pressForDuration:1];
        XCUIElement *action = self.app.buttons[@"Window action"];
        XCTAssertTrue([action waitForExistenceWithTimeout:3]);
        [action tap];
        [self dragElement:self.app.buttons[@"DockCollapse"] dx:(right.boolValue ? 18 : -18) dy:2 velocity:600];
        [self waitForStatus:@"hidden"];
        XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
        [self.app terminate];
    }
}
@end
