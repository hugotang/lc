#import <XCTest/XCTest.h>
#import "../TweakLoader/TapSyncWindow.h"
#import "TapSyncTestWindow.h"

// Stub only the scene enumeration used by window selection. Constructing another UIKit
// scene with the host's session reattaches its windows and invalidates geometry tests.
@interface LCTestScene : NSObject
@property(nonatomic) UISceneActivationState testActivation;
@property(nonatomic, copy) NSArray<UIWindow *> *testWindows;
@end
@implementation LCTestScene
- (BOOL)isKindOfClass:(Class)class { return class == UIWindowScene.class || [super isKindOfClass:class]; }
- (UISceneActivationState)activationState { return self.testActivation; }
- (NSArray<UIWindow *> *)windows { return self.testWindows ?: @[]; }
@end

@interface LCTestWindow : UIWindow
@property(nonatomic) BOOL testKey;
@property(nonatomic) BOOL passesTouches;
@end
@implementation LCTestWindow
- (BOOL)isKeyWindow { return self.testKey; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return self.passesTouches ? nil : [super hitTest:point withEvent:event];
}
@end

@interface LCTestDrawingView : UIView
@end
@implementation LCTestDrawingView
- (void)drawRect:(CGRect)rect {
    [UIColor.redColor setFill];
    UIRectFill(rect);
}
@end

@interface _LCTestAppGestureRecognizer : UITapGestureRecognizer
@end
@implementation _LCTestAppGestureRecognizer
@end

@interface TapSyncWindowTests : XCTestCase
@property(nonatomic) NSMutableArray<UIWindow *> *createdWindows;
@end
@implementation TapSyncWindowTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.createdWindows = [NSMutableArray array];
}
- (void)tearDown {
    for (UIWindow *window in self.createdWindows) {
        window.hidden = YES;
        window.windowScene = nil;
        window.rootViewController = nil;
    }
    [LCTapSyncTestHostWindow() makeKeyWindow];
    self.createdWindows = nil;
    [super tearDown];
}
- (UIWindowScene *)connectedScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    XCTFail(@"The test host must have an active connected UIWindowScene");
    return nil;
}
- (LCTestScene *)scene {
    LCTestScene *scene = [LCTestScene new];
    scene.testActivation = UISceneActivationStateForegroundActive;
    return scene;
}
- (LCTestWindow *)windowInScene:(UIWindowScene *)scene level:(CGFloat)level {
    LCTestWindow *window = [[LCTestWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(0, 0, 1024, 768);
    [self.createdWindows addObject:window];
    window.windowLevel = level;
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.frame = window.bounds;
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    window.hidden = NO;
    [window layoutIfNeeded];
    XCTAssertEqual(window.rootViewController.view.window, window);
    XCTAssertNotNil([window hitTest:CGPointMake(100, 100) withEvent:nil]);
    window.testKey = level == UIWindowLevelNormal;
    return window;
}
- (void)testEmptyAndPassThroughAuxiliaryWindows {
    UIWindowScene *scene = [self connectedScene];
    UIWindow *guest = LCTapSyncTestHostWindow();
    XCTAssertNotNil(guest);
    [guest makeKeyWindow];
    LCTestWindow *overlay = [self windowInScene:scene level:UIWindowLevelAlert];
    overlay.frame = guest.bounds;
    overlay.rootViewController.view.frame = overlay.bounds;
    [overlay layoutIfNeeded];
    UIView *emptyWrapper = [[UIView alloc] initWithFrame:overlay.bounds];
    [overlay.rootViewController.view addSubview:emptyWrapper];
    XCTAssertTrue(CGRectEqualToRect([overlay convertRect:overlay.bounds toWindow:guest], guest.bounds));
    LCTapSyncResult result;
    XCTAssertEqual(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result), guest);
    XCTAssertEqual(result, LCTapSyncResultAccepted);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(20, 30, 80, 40);
    [overlay.rootViewController.view addSubview:button];
    overlay.passesTouches = YES;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, scene.windows));
    overlay.passesTouches = NO;
    XCTAssertEqual([overlay hitTest:CGPointMake(60, 50) withEvent:nil], button);
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, scene.windows));
    XCTAssertNil(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result));
    XCTAssertEqual(result, LCTapSyncResultWindowCovered);
    button.hidden = YES;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, scene.windows));
}
- (void)testSmallVisibleContentAndGestureReceivers {
    UIWindowScene *scene = [self connectedScene];
    LCTestWindow *guest = [self windowInScene:scene level:UIWindowLevelNormal];
    LCTestWindow *overlay = [self windowInScene:scene level:UIWindowLevelAlert];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(995, 5, 24, 18)];
    label.text = @"!";
    [overlay.rootViewController.view addSubview:label];
    // A small corner overlay is a blocker even though the whole-window centre is empty.
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    label.hidden = YES;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    UIView *receiver = [[UIView alloc] initWithFrame:CGRectMake(0, 300, 20, 40)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [receiver addGestureRecognizer:tap];
    [overlay.rootViewController.view addSubview:receiver];
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    tap.enabled = NO;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    LCTestDrawingView *drawing = [[LCTestDrawingView alloc] initWithFrame:CGRectMake(2, 2, 10, 10)];
    [overlay.rootViewController.view addSubview:drawing];
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    drawing.hidden = YES;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    // An app's own transparent window recognizer must still block. UIKit's
    // automatically installed private window recognizers must not.
    UITapGestureRecognizer *windowTap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [overlay addGestureRecognizer:windowTap];
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    windowTap.enabled = NO;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    _LCTestAppGestureRecognizer *customTap = [[_LCTestAppGestureRecognizer alloc] initWithTarget:nil action:nil];
    [overlay addGestureRecognizer:customTap];
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    customTap.enabled = NO;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
}
- (void)testVisibilityAndGuestRelativeCoordinates {
    UIWindowScene *scene = [self connectedScene];
    LCTestWindow *guest = [self windowInScene:scene level:UIWindowLevelNormal];
    LCTestWindow *overlay = [self windowInScene:scene level:UIWindowLevelAlert];
    overlay.rootViewController.view.backgroundColor = UIColor.blackColor;
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.hidden = YES;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.hidden = NO;
    overlay.alpha = 0;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.alpha = 1;
    overlay.userInteractionEnabled = NO;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.userInteractionEnabled = YES;
    overlay.frame = CGRectMake(1025, 0, 100, 100);
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.frame = CGRectMake(1020, 0, 100, 100);
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
    overlay.windowLevel = UIWindowLevelNormal - 1;
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest, overlay]));
}
- (void)testUnattachedWindowsAndAmbiguousContent {
    LCTestScene *scene = [self scene], *other = [self scene];
    LCTestWindow *guest = [self windowInScene:[self connectedScene] level:UIWindowLevelNormal];
    LCTestWindow *unrelated = [[LCTestWindow alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
    [self.createdWindows addObject:unrelated];
    unrelated.windowLevel = UIWindowLevelAlert;
    unrelated.rootViewController = [UIViewController new];
    unrelated.rootViewController.view.backgroundColor = UIColor.blackColor;
    unrelated.hidden = NO;
    unrelated.windowScene = nil;
    XCTAssertNil(unrelated.windowScene);
    scene.testWindows = @[guest];
    other.testWindows = @[unrelated];
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[unrelated, guest]));
    LCTapSyncResult result;
    XCTAssertEqual(LCTapSyncFindGuestWindow((id)[NSSet setWithArray:@[other, scene]], &result), guest);
    XCTAssertEqual(result, LCTapSyncResultAccepted);
    scene.testActivation = UISceneActivationStateBackground;
    XCTAssertNil(LCTapSyncFindGuestWindow((id)[NSSet setWithObject:scene], &result));
    XCTAssertEqual(result, LCTapSyncResultSceneInactive);
    scene.testActivation = UISceneActivationStateForegroundActive;
    LCTestWindow *second = [self windowInScene:[self connectedScene] level:UIWindowLevelNormal];
    guest.testKey = NO;
    second.testKey = NO;
    scene.testWindows = @[guest, second];
    XCTAssertNil(LCTapSyncFindGuestWindow((id)[NSSet setWithObject:scene], &result));
    XCTAssertEqual(result, LCTapSyncResultWindowNotReady);
    second.testKey = YES;
    XCTAssertEqual(LCTapSyncFindGuestWindow((id)[NSSet setWithObject:scene], &result), second);
    guest.testKey = YES;
    XCTAssertNil(LCTapSyncFindGuestWindow((id)[NSSet setWithObject:scene], &result));
}
- (void)testRealPresentedAlerts {
    UIWindow *guest = LCTapSyncTestHostWindow();
    XCTAssertNotNil(guest);
    [guest makeKeyWindow];
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest]));
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Test" message:@"Dialog" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    XCTestExpectation *shown = [self expectationWithDescription:@"alert shown"];
    [guest.rootViewController presentViewController:alert animated:NO completion:^{ [shown fulfill]; }];
    [self waitForExpectations:@[shown] timeout:5];
    XCTAssertTrue(LCTapSyncWindowIsCovered(guest, @[guest]));
    XCTestExpectation *dismissed = [self expectationWithDescription:@"alert dismissed"];
    [guest.rootViewController dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
    [self waitForExpectations:@[dismissed] timeout:5];
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[guest]));
}
@end
