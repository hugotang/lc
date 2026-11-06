#import <XCTest/XCTest.h>
#include <math.h>

@interface LocationPickerUITests : XCTestCase
@property(nonatomic, strong) XCUIApplication *app;
@end
@implementation LocationPickerUITests
- (void)setUp {
    [super setUp]; self.continueAfterFailure = NO;
    self.app = [XCUIApplication new];
    self.app.launchArguments = @[@"-AppleLanguages", @"(en)", @"-AppleLocale", @"en_US"];
    [self.app launch];
    XCTAssertTrue([[self.app.switches matchingIdentifier:@"location.enabled"].firstMatch waitForExistenceWithTimeout:15]);
}
- (void)tearDown { [self.app terminate]; [super tearDown]; }
- (void)waitForElement:(XCUIElement *)element matching:(NSPredicate *)predicate {
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:element];
    [self waitForExpectations:@[expectation] timeout:10];
}
- (void)waitForLabel:(NSString *)label identifier:(NSString *)identifier {
    [self waitForElement:self.app.staticTexts[identifier]
               matching:[NSPredicate predicateWithFormat:@"exists == YES AND label == %@", label]];
}
- (void)waitForAbsent:(NSString *)identifier {
    XCUIElement *element = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:identifier].firstMatch;
    [self waitForElement:element matching:[NSPredicate predicateWithFormat:@"exists == NO"]];
}
- (void)tapWhenReady:(XCUIElement *)element {
    [self waitForElement:element matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES AND enabled == YES"]];
    [element tap];
}
- (void)revealSettingsControl:(XCUIElement *)element {
    for (NSUInteger attempt = 0; attempt < 4 && !element.hittable; attempt++) [self.app swipeUp];
    [self waitForElement:element matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES"]];
}
- (XCUIElement *)switchControl:(NSString *)identifier {
    XCUIElement *row = [self.app.switches matchingIdentifier:identifier].firstMatch;
    XCTAssertTrue([row waitForExistenceWithTimeout:10]);
    // SwiftUI exposes both the whole row and the trailing UISwitch. Its row
    // center is blank space. firstMatch also handles duplicate row/control IDs.
    XCUIElement *control = row.switches.firstMatch;
    return control.exists ? control : row;
}
- (void)toggleLocation {
    [self tapWhenReady:[self switchControl:@"location.enabled"]];
}
- (void)setShortcutEnabled:(BOOL)enabled {
    [self revealSettingsControl:[self.app.switches matchingIdentifier:@"location.shortcutEnabled"].firstMatch];
    XCUIElement *control = [self switchControl:@"location.shortcutEnabled"];
    NSString *value = enabled ? @"1" : @"0";
    if (![control.value isEqual:value]) [self tapWhenReady:control];
    [self waitForElement:control matching:[NSPredicate predicateWithFormat:@"value == %@", value]];
}
- (void)openLiveControls {
    XCUIElement *open = self.app.buttons[@"location.openControls"];
    [self revealSettingsControl:open];
    [self tapWhenReady:open];
    [self waitForElement:self.app.buttons[@"location.collapse"]
               matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES"]];
}
- (void)assertNoLocationOverlay {
    for (NSString *identifier in @[@"location.compactJoystick", @"location.quickControl", @"location.collapse",
                                   @"location.liveChoose", @"location.motionStatus"]) {
        [self waitForAbsent:identifier];
    }
}
- (void)assertCompactJoystick {
    XCUIElement *compact = self.app.otherElements[@"location.compactJoystick"];
    [self waitForElement:compact matching:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        (void)bindings;
        XCUIElement *element = object;
        return element.exists && element.frame.size.width > 0 && element.frame.size.height > 0 &&
            CGRectContainsRect(self.app.frame, element.frame);
    }]];
    // Accessibility converts through screen coordinates; fractional origins
    // can leave a subpixel rounding remainder in the reported dimensions.
    XCTAssertEqualWithAccuracy(compact.frame.size.width, 184.0, 0.5);
    XCTAssertEqualWithAccuracy(compact.frame.size.height, 228.0, 0.5);
    for (NSString *identifier in @[@"location.joystickSettings", @"location.joystickSpeed", @"location.joystickDrag"]) {
        [self waitForElement:self.app.buttons[identifier]
                   matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES"]];
    }
    XCTAssertTrue([self.app.buttons[@"location.stopMoving"] waitForExistenceWithTimeout:10]);
    for (NSString *identifier in @[@"location.liveCoordinate", @"location.motionStatus", @"location.liveChoose",
                                   @"location.favorites", @"location.joystickToggle", @"location.restoreReal", @"location.quickControl"]) {
        [self waitForAbsent:identifier];
    }
}
- (void)openCoordinates {
    [self tapWhenReady:self.app.buttons[@"location.coordinates"]];
    XCTAssertTrue([self.app.textFields[@"lc.location.latitude"] waitForExistenceWithTimeout:10]);
}
- (void)enter:(NSString *)value field:(NSString *)identifier {
    XCUIElement *field = self.app.textFields[identifier];
    [self tapWhenReady:field];
    NSString *existing = [field.value isKindOfClass:NSString.class] ? field.value : @"";
    if (existing.length && ![existing isEqual:field.placeholderValue]) {
        NSMutableString *deletes = [NSMutableString new];
        for (NSUInteger i = 0; i < existing.length; i++) [deletes appendString:XCUIKeyboardKeyDelete];
        [field typeText:deletes];
    }
    [field typeText:value];
}
- (void)selectCoordinatePair:(NSString *)pair expected:(NSString *)coordinate {
    [self openCoordinates];
    [self enter:pair field:@"location.coordinatePair"];
    [self tapWhenReady:self.app.buttons[@"location.keyboardDone"]];
    [self waitForElement:self.app.keyboards.firstMatch matching:[NSPredicate predicateWithFormat:@"exists == NO"]];
    [self tapWhenReady:self.app.buttons[@"location.showOnMap"]];
    // A dismissed nested sheet can remain in the accessibility snapshot.
    // Wait for the visible destination instead of the old field's removal.
    [self waitForElement:self.app.staticTexts[@"location.selectedCoordinate"]
               matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES AND label == %@", coordinate]];
    [self waitForLabel:coordinate identifier:@"location.selectedCoordinate"];
}
- (void)attachScreenshot {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:self.app.screenshot];
    attachment.name = @"Custom location picker"; attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}
- (void)testEnableCancelAndZeroCoordinateCommit {
    XCTAssertEqualObjects([self switchControl:@"location.enabled"].value, @"0");
    [self toggleLocation];
    XCTAssertTrue([self.app.buttons[@"location.cancel"] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(self.app.buttons[@"location.save"].enabled);
    [self.app.buttons[@"location.cancel"] tap];
    [self waitForAbsent:@"location.cancel"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '0'"]];
    [self toggleLocation];
    [self openCoordinates];
    [self enter:@"0" field:@"lc.location.latitude"]; [self enter:@"0" field:@"lc.location.longitude"];
    XCTAssertTrue(self.app.buttons[@"location.showOnMap"].enabled);
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"0.000000, 0.000000");
    [self attachScreenshot];
    [self.app.buttons[@"location.save"] tap];
    [self waitForAbsent:@"location.save"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '1'"]];
    [self toggleLocation];
    XCTAssertTrue([self.app.staticTexts[@"0.000000, 0.000000"] exists]);
}
- (void)testNegativeCoordinateValidationAndCancelPreservesSavedPoint {
    [self.app.buttons[@"location.choose"] tap]; [self openCoordinates];
    [self enter:@"91" field:@"lc.location.latitude"]; [self enter:@"0" field:@"lc.location.longitude"];
    XCTAssertFalse(self.app.buttons[@"location.showOnMap"].enabled);
    XCTAssertTrue(self.app.staticTexts[@"location.invalid"].exists);
    [self enter:@"33.8688" field:@"lc.location.latitude"];
    XCTAssertGreaterThanOrEqual(self.app.buttons[@"lc.location.latitude.sign"].frame.size.width, 44.0);
    XCTAssertGreaterThanOrEqual(self.app.buttons[@"lc.location.latitude.sign"].frame.size.height, 44.0);
    [self.app.buttons[@"lc.location.latitude.sign"] tap];
    XCTAssertEqualObjects(self.app.textFields[@"lc.location.latitude"].value, @"-33.8688");
    XCTAssertTrue(self.app.keyboards.firstMatch.exists);
    [self.app.buttons[@"lc.location.latitude.sign"] tap];
    XCTAssertEqualObjects(self.app.textFields[@"lc.location.latitude"].value, @"33.8688");
    [self.app.buttons[@"lc.location.latitude.sign"] tap];
    XCTAssertEqualObjects(self.app.textFields[@"lc.location.latitude"].value, @"-33.8688");
    [self attachScreenshot];
    [self.app.buttons[@"location.keyboardDone"] tap];
    XCTNSPredicateExpectation *keyboardHidden = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] object:self.app.keyboards.firstMatch];
    [self waitForExpectations:@[keyboardHidden] timeout:5];
    [self enter:@"151.2093" field:@"lc.location.longitude"];
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"-33.868800, 151.209300");
    [self.app.buttons[@"location.save"] tap];
    [self waitForAbsent:@"location.save"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '0'"]];
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
    [self attachScreenshot];
    [self.app.buttons[@"location.keyboardDone"] tap];
    [self.app.buttons[@"location.showOnMap"] tap];
    XCTAssertTrue([self.app.staticTexts[@"location.selectedCoordinate"] waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(self.app.staticTexts[@"location.selectedCoordinate"].label, @"-33.868800, 151.209300");
    [self.app.buttons[@"location.save"] tap];
}
- (void)testLivePanelJoystickReleaseFavoritesAndRestoreSystemLocation {
    [self toggleLocation];
    [self selectCoordinatePair:@"22, 114" expected:@"22.000000, 114.000000"];
    [self tapWhenReady:self.app.buttons[@"location.save"]];
    [self waitForAbsent:@"location.save"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '1'"]];
    [self setShortcutEnabled:YES];
    [self openLiveControls];
    [self tapWhenReady:self.app.buttons[@"location.favorites"]];
    [self tapWhenReady:self.app.buttons[@"Save Current Place"]];
    [self tapWhenReady:self.app.buttons[@"location.joystickToggle"]];
    [self assertCompactJoystick];
    XCUIElement *stick = self.app.otherElements[@"location.joystick"];
    [self waitForElement:stick matching:[NSPredicate predicateWithFormat:@"exists == YES AND value == %@", @"22.000000, 114.000000"]];
    NSString *before = [stick.value copy];
    [[stick coordinateWithNormalizedOffset:CGVectorMake(0.8, 0.5)] pressForDuration:2.3];
    [self waitForElement:stick matching:[NSPredicate predicateWithFormat:@"value != nil AND value != %@", before]];
    XCUIElement *stop = self.app.buttons[@"location.stopMoving"];
    [self waitForElement:stop matching:[NSPredicate predicateWithFormat:@"exists == YES AND enabled == NO"]];
    NSString *released = [stick.value copy];
    // Cover more than two movement timer ticks after release, without sleeping.
    XCTNSPredicateExpectation *keepsMoving = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"value != %@", released] object:stick];
    keepsMoving.inverted = YES;
    [self waitForExpectations:@[keepsMoving] timeout:2.5];

    // Only the drag handle moves the panel. Drag toward each screen corner;
    // the compact frame must stay bounded and the stopped point must not move.
    for (NSValue *corner in @[[NSValue valueWithCGPoint:CGPointMake(0.95, 0.15)],
                              [NSValue valueWithCGPoint:CGPointMake(0.95, 0.90)],
                              [NSValue valueWithCGPoint:CGPointMake(0.05, 0.15)],
                              [NSValue valueWithCGPoint:CGPointMake(0.05, 0.90)]]) {
        XCUIElement *compact = self.app.otherElements[@"location.compactJoystick"];
        CGRect oldFrame = compact.frame, handle = self.app.buttons[@"location.joystickDrag"].frame, screen = self.app.frame;
        XCUICoordinate *origin = [self.app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
        XCUICoordinate *start = [origin coordinateWithOffset:CGVectorMake(CGRectGetMidX(handle) - CGRectGetMinX(screen),
                                                                       CGRectGetMidY(handle) - CGRectGetMinY(screen))];
        CGPoint target = corner.CGPointValue;
        XCUICoordinate *end = [self.app coordinateWithNormalizedOffset:CGVectorMake(target.x, target.y)];
        [start pressForDuration:0.05 thenDragToCoordinate:end withVelocity:500 thenHoldForDuration:0];
        [self waitForElement:compact matching:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            (void)bindings;
            XCUIElement *element = object;
            return element.exists && !CGRectEqualToRect(oldFrame, element.frame);
        }]];
        [self assertCompactJoystick];
        XCTAssertEqualObjects(stick.value, released);
        XCTAssertFalse(stop.enabled);
    }
    [self attachScreenshot];
    [self tapWhenReady:self.app.buttons[@"location.joystickSettings"]];
    [self waitForAbsent:@"location.compactJoystick"];
    [self waitForLabel:released identifier:@"location.liveCoordinate"];
    [self waitForLabel:@"Custom location · stationary" identifier:@"location.motionStatus"];
    // The overlay picker temporarily owns keyboard focus. Dismissing it must
    // return to the same live panel and update the saved point immediately.
    [self tapWhenReady:self.app.buttons[@"location.liveChoose"]];
    [self selectCoordinatePair:@"23, 115" expected:@"23.000000, 115.000000"];
    [self tapWhenReady:self.app.buttons[@"location.save"]];
    [self waitForAbsent:@"location.save"];
    [self waitForLabel:@"23.000000, 115.000000" identifier:@"location.liveCoordinate"];
    [self tapWhenReady:self.app.buttons[@"location.collapse"]];
    [self waitForAbsent:@"location.collapse"];
    [self tapWhenReady:self.app.buttons[@"location.quickControl"]];
    XCUIElement *restore = self.app.buttons[@"location.restoreReal"];
    if (!restore.hittable) [self.app swipeUp];
    [self tapWhenReady:restore];
    // Tap the actual nested control, as with the SwiftUI switch row above.
    XCUIElement *confirmation = [self.app.buttons matchingIdentifier:@"location.confirmRestoreReal"].firstMatch;
    XCTAssertTrue([confirmation waitForExistenceWithTimeout:10]);
    XCUIElement *inner = confirmation.buttons.firstMatch;
    [self tapWhenReady:inner.exists ? inner : confirmation];
    [self waitForLabel:@"Using system location" identifier:@"location.motionStatus"];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    [self.app activate];
    XCTAssertTrue([self.app.buttons[@"location.quickControl"] waitForExistenceWithTimeout:10]);
    [self waitForAbsent:@"location.collapse"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '0'"]];
}

- (void)testShortcutChangesImmediatelyAndOffCollapseLeavesNoBubble {
    XCTAssertEqualObjects([self switchControl:@"location.shortcutEnabled"].value, @"0");
    [self assertNoLocationOverlay];
    [self setShortcutEnabled:YES];
    XCTAssertTrue([self.app.buttons[@"location.quickControl"] waitForExistenceWithTimeout:10]);
    [self setShortcutEnabled:NO];
    [self assertNoLocationOverlay];

    // Opening controls manually must not opt in to a persistent shortcut.
    // Repeating also exercises reuse of the overlay hidden by the first collapse.
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        [self openLiveControls];
        [self waitForLabel:@"Using system location" identifier:@"location.motionStatus"];
        [self waitForAbsent:@"location.quickControl"];
        [self tapWhenReady:self.app.buttons[@"location.collapse"]];
        [self assertNoLocationOverlay];
        XCTAssertEqualObjects([self switchControl:@"location.shortcutEnabled"].value, @"0");
    }
    [self setShortcutEnabled:YES];
    [self tapWhenReady:self.app.buttons[@"location.quickControl"]];
    [self tapWhenReady:self.app.buttons[@"location.collapse"]];
    [self waitForAbsent:@"location.collapse"];
    XCTAssertTrue([self.app.buttons[@"location.quickControl"] waitForExistenceWithTimeout:10]);
    [self setShortcutEnabled:NO];
    [self assertNoLocationOverlay];
}

- (void)testCompactJoystickPassesTouchesThroughToShortcutSwitch {
    [self toggleLocation];
    [self selectCoordinatePair:@"22, 114" expected:@"22.000000, 114.000000"];
    [self tapWhenReady:self.app.buttons[@"location.save"]];
    [self waitForAbsent:@"location.save"];
    [self setShortcutEnabled:YES];
    [self openLiveControls];
    [self tapWhenReady:self.app.buttons[@"location.joystickToggle"]];
    [self assertCompactJoystick];

    // Tap the actual underlying switch while compact controls are still open.
    // A full-window overlay hit target would block this even if it looks clear.
    XCUIElement *shortcut = [self switchControl:@"location.shortcutEnabled"];
    [self waitForElement:shortcut matching:[NSPredicate predicateWithFormat:@"exists == YES AND hittable == YES"]];
    XCTAssertFalse(CGRectIntersectsRect(shortcut.frame, self.app.otherElements[@"location.compactJoystick"].frame));
    [self tapWhenReady:shortcut];
    [self waitForElement:shortcut matching:[NSPredicate predicateWithFormat:@"value == '0'"]];
    [self assertNoLocationOverlay];

    // Compact collapse follows the same opt-in rule as detail collapse.
    [self openLiveControls];
    [self tapWhenReady:self.app.buttons[@"location.joystickToggle"]];
    [self assertCompactJoystick];
    [self tapWhenReady:self.app.buttons[@"location.collapse"]];
    [self assertNoLocationOverlay];
    [self setShortcutEnabled:YES];
    [self tapWhenReady:self.app.buttons[@"location.quickControl"]];
    [self tapWhenReady:self.app.buttons[@"location.joystickToggle"]];
    [self assertCompactJoystick];
    [self tapWhenReady:self.app.buttons[@"location.collapse"]];
    [self waitForAbsent:@"location.compactJoystick"];
    XCTAssertTrue([self.app.buttons[@"location.quickControl"] waitForExistenceWithTimeout:10]);
}

- (void)testMapBaselineAndDraftRemainIndependentWhenSavedOrCurrent {
    [self tapWhenReady:self.app.buttons[@"location.choose"]];
    [self selectCoordinatePair:@"22, 114" expected:@"22.000000, 114.000000"];
    [self tapWhenReady:self.app.buttons[@"location.save"]];
    [self waitForAbsent:@"location.save"];
    [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '0'"]];

    for (NSNumber *enabled in @[@NO, @YES]) {
        if (enabled.boolValue) {
            [self toggleLocation];
            [self waitForElement:[self switchControl:@"location.enabled"] matching:[NSPredicate predicateWithFormat:@"value == '1'"]];
        }
        NSString *role = enabled.boolValue ? @"Current Location" : @"Saved Location";
        [self tapWhenReady:self.app.buttons[@"location.choose"]];
        [self waitForLabel:role identifier:@"location.baselineRole"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.baselineCoordinate"];
        [self waitForLabel:@"Selected Location" identifier:@"location.pendingRole"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.selectedCoordinate"];

        [self selectCoordinatePair:@"23, 115" expected:@"23.000000, 115.000000"];
        [self waitForLabel:role identifier:@"location.baselineRole"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.baselineCoordinate"];
        [self waitForLabel:@"Selected Location" identifier:@"location.pendingRole"];
        [self attachScreenshot];
        [self tapWhenReady:self.app.buttons[@"location.returnBaseline"]];
        [self waitForLabel:@"23.000000, 115.000000" identifier:@"location.selectedCoordinate"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.baselineCoordinate"];

        // Read the camera via the production Use Map Center action. Only that
        // action should change the draft; no tiles, search or real GPS required.
        [self tapWhenReady:self.app.buttons[@"location.center"]];
        [self waitForElement:self.app.staticTexts[@"location.selectedCoordinate"]
                   matching:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            (void)bindings;
            XCUIElement *element = object;
            if (!element.exists) return NO;
            NSArray<NSString *> *parts = [element.label componentsSeparatedByString:@", "];
            return parts.count == 2 && fabs(parts[0].doubleValue - 22) < 0.0001 &&
                fabs(parts[1].doubleValue - 114) < 0.0001;
        }]];
        [self waitForLabel:role identifier:@"location.baselineRole"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.baselineCoordinate"];
        [self waitForLabel:@"Selected Location" identifier:@"location.pendingRole"];
        // Leave a distinct draft when cancelling, then reopen to verify that
        // neither the persisted point nor its saved/current role was changed.
        [self selectCoordinatePair:@"24, 116" expected:@"24.000000, 116.000000"];
        [self tapWhenReady:self.app.buttons[@"location.cancel"]];
        [self waitForAbsent:@"location.cancel"];
        [self waitForElement:[self switchControl:@"location.enabled"]
                   matching:[NSPredicate predicateWithFormat:@"value == %@", enabled.boolValue ? @"1" : @"0"]];
        [self tapWhenReady:self.app.buttons[@"location.choose"]];
        [self waitForLabel:role identifier:@"location.baselineRole"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.baselineCoordinate"];
        [self waitForLabel:@"22.000000, 114.000000" identifier:@"location.selectedCoordinate"];
        [self tapWhenReady:self.app.buttons[@"location.cancel"]];
        [self waitForAbsent:@"location.cancel"];
    }
}
@end
