#import <XCTest/XCTest.h>

@interface LocationPickerUITests : XCTestCase
@property(nonatomic, strong) XCUIApplication *app;
@end
@implementation LocationPickerUITests
- (void)setUp {
    [super setUp]; self.continueAfterFailure = NO;
    self.app = [XCUIApplication new];
    self.app.launchArguments = @[@"-AppleLanguages", @"(en)", @"-AppleLocale", @"en_US"];
    [self.app launch];
    XCTAssertTrue([self.app.switches[@"location.enabled"] waitForExistenceWithTimeout:15]);
}
- (void)tearDown { [self.app terminate]; [super tearDown]; }
- (void)toggleLocation {
    XCUIElement *row = self.app.switches[@"location.enabled"];
    // SwiftUI exposes both the whole row and the trailing UISwitch. Its row
    // center is blank space; tap the actual switch without screen coordinates.
    XCUIElement *control = row.switches.firstMatch;
    [(control.exists ? control : row) tap];
}
- (void)openCoordinates {
    XCTAssertTrue([self.app.buttons[@"location.coordinates"] waitForExistenceWithTimeout:10]);
    [self.app.buttons[@"location.coordinates"] tap];
    XCTAssertTrue([self.app.textFields[@"lc.location.latitude"] waitForExistenceWithTimeout:10]);
}
- (void)enter:(NSString *)value field:(NSString *)identifier {
    XCUIElement *field = self.app.textFields[identifier];
    [field tap];
    NSString *existing = [field.value isKindOfClass:NSString.class] ? field.value : @"";
    if (existing.length && ![existing isEqual:field.placeholderValue]) {
        NSMutableString *deletes = [NSMutableString new];
        for (NSUInteger i = 0; i < existing.length; i++) [deletes appendString:XCUIKeyboardKeyDelete];
        [field typeText:deletes];
    }
    [field typeText:value];
}
- (void)attachScreenshot {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:self.app.screenshot];
    attachment.name = @"Custom location picker"; attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}
- (void)testEnableCancelAndZeroCoordinateCommit {
    XCTAssertEqualObjects(self.app.switches[@"location.enabled"].value, @"0");
    [self toggleLocation];
    XCTAssertTrue([self.app.buttons[@"location.cancel"] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(self.app.buttons[@"location.save"].enabled);
    [self.app.buttons[@"location.cancel"] tap];
    XCTAssertEqualObjects(self.app.switches[@"location.enabled"].value, @"0");
    [self toggleLocation];
    [self openCoordinates];
    [self enter:@"0" field:@"lc.location.latitude"]; [self enter:@"0" field:@"lc.location.longitude"];
    XCTAssertTrue(self.app.buttons[@"location.showOnMap"].enabled);
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"0.000000, 0.000000");
    [self attachScreenshot];
    [self.app.buttons[@"location.save"] tap];
    XCTAssertEqualObjects(self.app.switches[@"location.enabled"].value, @"1");
    [self toggleLocation];
    XCTAssertTrue([self.app.staticTexts[@"0.000000, 0.000000"] exists]);
}
- (void)testNegativeCoordinateValidationAndCancelPreservesSavedPoint {
    [self.app.buttons[@"location.choose"] tap]; [self openCoordinates];
    [self enter:@"91" field:@"lc.location.latitude"]; [self enter:@"0" field:@"lc.location.longitude"];
    XCTAssertFalse(self.app.buttons[@"location.showOnMap"].enabled);
    XCTAssertTrue(self.app.staticTexts[@"location.invalid"].exists);
    [self enter:@"33.8688" field:@"lc.location.latitude"];
    [self.app.buttons[@"lc.location.latitude.sign"] tap];
    [self enter:@"151.2093" field:@"lc.location.longitude"];
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"-33.868800, 151.209300");
    [self.app.buttons[@"location.save"] tap];
    XCTAssertEqualObjects(self.app.switches[@"location.enabled"].value, @"0");
    [self.app.buttons[@"location.choose"] tap]; [self openCoordinates];
    [self enter:@"22" field:@"lc.location.latitude"];
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.buttons[@"location.cancel"] waitForExistenceWithTimeout:10]);
    [self.app.buttons[@"location.cancel"] tap];
    XCTAssertTrue([self.app.staticTexts[@"-33.868800, 151.209300"] exists]);
}
- (void)testCoordinatePairValidationAndKeyboardDone {
    [self.app.buttons[@"location.choose"] tap]; [self openCoordinates];
    [self enter:@"22.3193, 114.1694" field:@"location.coordinatePair"];
    XCTAssertTrue(self.app.buttons[@"location.showOnMap"].enabled);
    [self enter:@"91, 0" field:@"location.coordinatePair"];
    XCTAssertFalse(self.app.buttons[@"location.showOnMap"].enabled);
    XCTAssertTrue(self.app.staticTexts[@"location.invalid"].exists);
    [self enter:@"-33.8688, 151.2093" field:@"location.coordinatePair"];
    [self.app.buttons[@"location.keyboardDone"] tap];
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"-33.868800, 151.209300");
    [self.app.buttons[@"location.save"] tap];
}
- (void)testLivePanelJoystickReleaseFavoritesAndRestoreSystemLocation {
    [self toggleLocation]; [self openCoordinates];
    [self enter:@"22" field:@"lc.location.latitude"]; [self enter:@"114" field:@"lc.location.longitude"];
    [self.app.buttons[@"location.showOnMap"] tap];
    [self.app.buttons[@"location.save"] tap];
    XCUIElement *open = self.app.buttons[@"location.openControls"];
    if (!open.hittable) [self.app swipeUp];
    [open tap];
    XCTAssertTrue([self.app.buttons[@"location.joystickToggle"] waitForExistenceWithTimeout:10]);
    [self.app.buttons[@"location.favorites"] tap];
    [self.app.buttons[@"Save Current Place"] tap];
    [self.app.buttons[@"location.joystickToggle"] tap];
    XCUIElement *stick = self.app.otherElements[@"location.joystick"];
    XCTAssertTrue([stick waitForExistenceWithTimeout:10]);
    NSString *before = self.app.staticTexts[@"location.liveCoordinate"].label;
    [[stick coordinateWithNormalizedOffset:CGVectorMake(0.8, 0.5)] pressForDuration:2.3];
    XCTAssertNotEqualObjects(self.app.staticTexts[@"location.liveCoordinate"].label, before);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.motionStatus"].label, @"Custom location · stationary");
    [self attachScreenshot];
    [self.app.buttons[@"location.collapse"] tap];
    XCTAssertTrue([self.app.buttons[@"location.quickControl"] waitForExistenceWithTimeout:10]);
    [self.app.buttons[@"location.quickControl"] tap];
    XCUIElement *restore = self.app.buttons[@"location.restoreReal"];
    if (!restore.hittable) [self.app swipeUp];
    [restore tap];
    [self.app.buttons[@"location.confirmRestoreReal"] tap];
    XCTAssertEqualObjects(self.app.staticTexts[@"location.motionStatus"].label, @"Using system location");
    [self.app.buttons[@"location.collapse"] tap];
    XCTAssertEqualObjects(self.app.switches[@"location.enabled"].value, @"0");
}
@end
