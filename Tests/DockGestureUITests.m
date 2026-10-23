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
    self.app.launchArguments = @[(right ? @"--right" : @"--left"), (narrow ? @"--narrow" : @"--default")];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"DockAccount0"] waitForExistenceWithTimeout:5]);
}
- (void)waitForStatus:(NSString *)status {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label == %@", status];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:self.app.staticTexts[@"DockStatus"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:5], XCTWaiterResultCompleted);
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
    [self launchRight:YES narrow:NO];
    [self dragElement:self.app.buttons[@"DockMenu"] dx:22 dy:4 hold:0];
    [self waitForStatus:@"hidden"];
    XCTAssertEqualObjects(self.app.staticTexts[@"DockTaps"].label, @"0");
}
@end
