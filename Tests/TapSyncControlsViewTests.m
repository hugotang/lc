#import <XCTest/XCTest.h>
#import "../MultitaskSupport/TapSyncControlsView.h"
#import "../MultitaskSupport/TapSyncCoordinator.h"
#import "../MultitaskSupport/TapSyncRecovery.h"
#import "../MultitaskSupport/PerformanceMonitor.h"
#import "../LiveContainer/Localization.h"
#import "../LiveContainer/utils.h"
#import "TapSyncTestWindow.h"
#include <math.h>

// The UIKit host supplies real localized strings, without the app's bundle
// redirect or its performance sampler. Neither test double is packaged.
@implementation NSUserDefaults (LCTapSyncControlsTestBundle)
+ (NSBundle *)lcMainBundle { return NSBundle.mainBundle; }
@end

@implementation LCPerformanceMonitor
+ (instancetype)shared {
    static LCPerformanceMonitor *monitor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ monitor = [self new]; });
    return monitor;
}
- (void)updateVisibility {}
- (void)resetMeasurements {}
@end

@interface TapSyncControlsViewTests : XCTestCase
@property(nonatomic) LCTapSyncControlsView *controls;
@property(nonatomic) LCTapSyncCoordinator *sync;
@end

@implementation TapSyncControlsViewTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.sync = LCTapSyncCoordinator.shared;
    [self.sync selectSource:@"A" targets:@[@"B", @"C", @"D"]];
    [self.sync setValue:@{@"B": @1, @"C": @2, @"D": @3} forKey:@"participantNumbers"];
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCTapSyncCompactControls"];
    self.controls = [LCTapSyncControlsView new];
    [LCTapSyncTestHostWindow().rootViewController.view addSubview:self.controls];
}
- (void)tearDown {
    [self.controls removeFromSuperview];
    [self.sync pause];
    [self.sync selectSource:nil targets:@[]];
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCTapSyncCompactControls"];
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCTapSyncControlsPortraitPosition"];
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCTapSyncControlsLandscapePosition"];
    self.controls = nil;
    self.sync = nil;
    [super tearDown];
}
- (UIButton *)toggleButton { return [self.controls valueForKey:@"toggleButton"]; }
- (UIButton *)settingsButton { return [self.controls valueForKey:@"settingsButton"]; }
- (void)layoutInPhoneBounds {
    [self.controls refresh];
    [self.controls placeInBounds:CGRectMake(0, 0, 320, 568) safeAreaInsets:UIEdgeInsetsZero];
    [self.controls layoutIfNeeded];
}
- (void)testSmallSyncedWindowsDefaultToIconsAndSavedChoiceTakesPrecedence {
    // iPhone windows, four iPad windows in either orientation, then two iPad windows.
    const CGSize compact[] = {{402, 437}, {874, 201}, {683, 512}, {512, 683}, {599, 1000}};
    const CGSize text[] = {{683, 1024}, {1024, 683}, {600, 900}};
    for (size_t index = 0; index < sizeof(compact) / sizeof(compact[0]); index++) {
        XCTAssertTrue([LCTapSyncControlsView prefersCompactControlsForSmallestWindowSize:compact[index]]);
        self.controls.smallestSyncedWindowSize = compact[index];
        [self layoutInPhoneBounds];
        XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
    }
    for (size_t index = 0; index < sizeof(text) / sizeof(text[0]); index++) {
        XCTAssertFalse([LCTapSyncControlsView prefersCompactControlsForSmallestWindowSize:text[index]]);
        self.controls.smallestSyncedWindowSize = text[index];
        [self layoutInPhoneBounds];
        XCTAssertGreaterThan(self.toggleButton.configuration.title.length, 0u);
    }
    // Before the windows are laid out, the device decides.
    BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    for (NSValue *unknown in @[[NSValue valueWithCGSize:CGSizeZero], [NSValue valueWithCGSize:CGSizeMake(NAN, 500)]]) {
        XCTAssertEqual([LCTapSyncControlsView prefersCompactControlsForSmallestWindowSize:unknown.CGSizeValue], phone);
    }
    // A saved choice wins in both directions, and the size updates the live controls.
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    self.controls.smallestSyncedWindowSize = text[0];
    [self layoutInPhoneBounds];
    XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
    [NSUserDefaults.lcSharedDefaults setBool:NO forKey:@"LCTapSyncCompactControls"];
    self.controls.smallestSyncedWindowSize = compact[0];
    [self layoutInPhoneBounds];
    XCTAssertGreaterThan(self.toggleButton.configuration.title.length, 0u);
}
- (void)testHostShapeSelectsSavedPosition {
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
    UIAccessibilityCustomAction *bottomRight = self.toggleButton.accessibilityCustomActions[3];
    // Split View and Stage Manager can give a portrait-shaped host in a
    // landscape scene. The shape decides, as it does for the grid and Dock.
    [self.controls placeInBounds:CGRectMake(0, 0, 507, 1024) safeAreaInsets:UIEdgeInsetsZero];
    XCTAssertTrue(bottomRight.actionHandler(bottomRight));
    XCTAssertNotNil([defaults dictionaryForKey:@"LCTapSyncControlsPortraitPosition"]);
    XCTAssertNil([defaults dictionaryForKey:@"LCTapSyncControlsLandscapePosition"]);
    [defaults removeObjectForKey:@"LCTapSyncControlsPortraitPosition"];
    [self.controls placeInBounds:CGRectMake(0, 0, 1366, 512) safeAreaInsets:UIEdgeInsetsZero];
    bottomRight = self.toggleButton.accessibilityCustomActions[3];
    XCTAssertTrue(bottomRight.actionHandler(bottomRight));
    XCTAssertNotNil([defaults dictionaryForKey:@"LCTapSyncControlsLandscapePosition"]);
    XCTAssertNil([defaults dictionaryForKey:@"LCTapSyncControlsPortraitPosition"]);
}
- (void)testIconsOfferLargeContentAndPointerDescriptions {
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    [self layoutInPhoneBounds];
    BOOL hasInteraction = NO;
    for (id<UIInteraction> interaction in self.controls.interactions) {
        hasInteraction |= [interaction isKindOfClass:UILargeContentViewerInteraction.class];
    }
    XCTAssertTrue(hasInteraction);
    for (UIButton *button in @[self.toggleButton, self.settingsButton]) {
        XCTAssertTrue(button.showsLargeContentViewer);
        XCTAssertGreaterThan(button.largeContentTitle.length, 0u);
        XCTAssertNotNil(button.largeContentImage);
        XCTAssertGreaterThan(button.toolTip.length, 0u);
    }
    XCTAssertEqualObjects(self.settingsButton.largeContentTitle, @"lc.tapSync.configure".loc);
    [self.sync setValue:@"lc.tapSync.expiredInput" forKey:@"statusKey"];
    [self.sync setValue:@[@"C"] forKey:@"interruptedContainers"];
    [self layoutInPhoneBounds];
    XCTAssertTrue([self.toggleButton.toolTip containsString:@"lc.tapSync.expiredInput".loc]);
    XCTAssertTrue([self.settingsButton.toolTip containsString:@"#2"]);
    // The enlarged title is the action, not the long reason.
    XCTAssertFalse([self.toggleButton.largeContentTitle containsString:@"lc.tapSync.expiredInput".loc]);
}
- (void)testLongFailureKeepsIconControlsSmallAndDetailsAccessible {
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    for (NSString *key in @[@"lc.tapSync.expiredInput", @"lc.tapSync.tooSlow", @"lc.tapSync.backgroundPaused"]) {
        [self.sync setValue:key forKey:@"statusKey"];
        [self.sync setValue:@[@"C"] forKey:@"interruptedContainers"];
        [self layoutInPhoneBounds];
        XCTAssertTrue(self.sync.hasInterruption);
        XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
        XCTAssertEqual(self.toggleButton.configuration.subtitle.length, 0u);
        XCTAssertNotNil(self.toggleButton.configuration.image);
        XCTAssertLessThanOrEqual(self.controls.bounds.size.width, 100);
        XCTAssertLessThanOrEqual(self.controls.bounds.size.height, 52);
        XCTAssertGreaterThanOrEqual(self.toggleButton.bounds.size.width, 44);
        XCTAssertGreaterThanOrEqual(self.toggleButton.bounds.size.height, 44);
        XCTAssertGreaterThanOrEqual(self.settingsButton.bounds.size.width, 44);
        XCTAssertTrue([self.toggleButton.accessibilityValue containsString:key.loc]);
        XCTAssertTrue([self.settingsButton.accessibilityValue containsString:@"#2"]);
        XCTAssertEqualObjects(self.toggleButton.accessibilityLabel, @"lc.tapSync.resume".loc);
    }
}
- (void)testPreparingAndReturningToSourceKeepIconControlsBounded {
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    [self.sync setValue:@YES forKey:@"starting"];
    [self.sync setValue:@"lc.tapSync.starting" forKey:@"statusKey"];
    [self layoutInPhoneBounds];
    XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
    XCTAssertEqual(self.toggleButton.configuration.subtitle.length, 0u);
    XCTAssertLessThanOrEqual(self.controls.bounds.size.width, 100);
    XCTAssertEqualObjects(self.toggleButton.accessibilityLabel, @"lc.tapSync.pause".loc);
    [self.sync setValue:@NO forKey:@"starting"];
    LCTapSyncRecovery *recovery = [[LCTapSyncRecovery alloc] initWithSource:@"A" targets:@[@"B", @"C", @"D"]
        reason:LCTapSyncRecoveryFollowerInput afterTime:NSProcessInfo.processInfo.systemUptime];
    [self.sync setValue:recovery forKey:@"recovery"];
    [self.sync setValue:@"lc.tapSync.waitingForSource" forKey:@"statusKey"];
    [self layoutInPhoneBounds];
    XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
    XCTAssertEqual(self.toggleButton.configuration.subtitle.length, 0u);
    XCTAssertLessThanOrEqual(self.controls.bounds.size.width, 100);
    XCTAssertTrue([self.settingsButton.accessibilityValue containsString:@"lc.tapSync.waitingForSource".loc]);
    [self.toggleButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertFalse(self.sync.recovering);
}
- (void)testActiveIconStillPausesAndKeepsTheSavedGroup {
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    [self.sync setValue:@YES forKey:@"active"];
    [self.sync setValue:@"lc.tapSync.active" forKey:@"statusKey"];
    [self layoutInPhoneBounds];
    XCTAssertEqual(self.toggleButton.configuration.title.length, 0u);
    XCTAssertEqual(self.toggleButton.configuration.subtitle.length, 0u);
    XCTAssertEqualObjects(self.toggleButton.accessibilityLabel, @"lc.tapSync.pause".loc);
    [self.toggleButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertFalse(self.sync.active);
    XCTAssertEqualObjects(self.sync.sourceContainer, @"A");
    XCTAssertEqualObjects(self.sync.targetContainers, (@[@"B", @"C", @"D"]));
}
- (void)testTextControlsKeepShortTitleAndGearStillOpensDetails {
    [NSUserDefaults.lcSharedDefaults setBool:NO forKey:@"LCTapSyncCompactControls"];
    [self.sync setValue:@"lc.tapSync.expiredInput" forKey:@"statusKey"];
    [self.sync setValue:@[@"C"] forKey:@"interruptedContainers"];
    [self layoutInPhoneBounds];
    XCTAssertGreaterThan(self.toggleButton.configuration.title.length, 0u);
    XCTAssertEqual(self.toggleButton.configuration.subtitle.length, 0u);
    __block NSUInteger opened = 0;
    self.controls.configure = ^{ opened++; };
    [self.settingsButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertEqual(opened, 1u);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.expiredInput");
    XCTAssertTrue([self.toggleButton.accessibilityValue containsString:@"lc.tapSync.expiredInput".loc]);
}
@end
