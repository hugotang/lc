#import <XCTest/XCTest.h>
#import "../TweakLoader/TapSyncWindow.h"

@interface LCTestScene : UIWindowScene
@property(nonatomic) UISceneActivationState testActivation;
@property(nonatomic, copy) NSArray<UIWindow *> *testWindows;
@end
@implementation LCTestScene
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

@interface TapSyncWindowTests : XCTestCase
@property(nonatomic) NSMutableArray<UIWindow *> *createdWindows;
@end
@implementation TapSyncWindowTests
- (void)setUp {
    [super setUp];
    self.createdWindows = [NSMutableArray array];
}
- (void)tearDown {
    for (UIWindow *window in self.createdWindows) {
        window.hidden = YES;
        window.windowScene = nil;
        window.rootViewController = nil;
    }
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
    UISceneSession *session = UIApplication.sharedApplication.openSessions.anyObject;
    XCTAssertNotNil(session);
    UISceneConnectionOptions *options = [(NSObject *)UIApplication.sharedApplication.delegate valueForKey:@"connectionOptions"];
    XCTAssertNotNil(options);
    LCTestScene *scene = [[LCTestScene alloc] initWithSession:session connectionOptions:options];
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
    LCTestWindow *guest = [self windowInScene:scene level:UIWindowLevelNormal];
    LCTestWindow *overlay = [self windowInScene:scene level:UIWindowLevelAlert];
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
    NSLog(@"Overlay bounds %@ -> %@, content %@, button %@, hit %@; levels %.0f/%.0f, hidden %d, interactive %d",
          NSStringFromCGRect(overlay.bounds), NSStringFromCGRect([overlay convertRect:overlay.bounds toWindow:guest]),
          NSStringFromCGRect([overlay.rootViewController.view convertRect:overlay.rootViewController.view.bounds toView:guest]),
          NSStringFromCGRect([button convertRect:button.bounds toView:guest]),
          [overlay hitTest:CGPointMake(60, 50) withEvent:nil], (double)guest.windowLevel, (double)overlay.windowLevel,
          overlay.hidden, overlay.userInteractionEnabled);
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
- (void)testOtherScenesAndAmbiguousContent {
    LCTestScene *scene = [self scene], *other = [self scene];
    LCTestWindow *guest = [self windowInScene:[self connectedScene] level:UIWindowLevelNormal];
    LCTestWindow *unrelated = [self windowInScene:other level:UIWindowLevelAlert];
    unrelated.rootViewController.view.backgroundColor = UIColor.blackColor;
    scene.testWindows = @[guest];
    other.testWindows = @[unrelated];
    XCTAssertFalse(LCTapSyncWindowIsCovered(guest, @[unrelated, guest]));
    LCTapSyncResult result;
    XCTAssertEqual(LCTapSyncFindGuestWindow([NSSet setWithArray:@[other, scene]], &result), guest);
    XCTAssertEqual(result, LCTapSyncResultAccepted);
    scene.testActivation = UISceneActivationStateBackground;
    XCTAssertNil(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result));
    XCTAssertEqual(result, LCTapSyncResultSceneInactive);
    scene.testActivation = UISceneActivationStateForegroundActive;
    LCTestWindow *second = [self windowInScene:[self connectedScene] level:UIWindowLevelNormal];
    guest.testKey = NO;
    second.testKey = NO;
    scene.testWindows = @[guest, second];
    XCTAssertNil(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result));
    XCTAssertEqual(result, LCTapSyncResultWindowNotReady);
    second.testKey = YES;
    XCTAssertEqual(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result), second);
    guest.testKey = YES;
    XCTAssertNil(LCTapSyncFindGuestWindow([NSSet setWithObject:scene], &result));
}
- (void)testRealPresentedAlerts {
    UIWindowScene *scene = [self connectedScene];
    UIWindow *guest = [[UIWindow alloc] initWithWindowScene:scene];
    [self.createdWindows addObject:guest];
    guest.rootViewController = [UIViewController new];
    [guest makeKeyAndVisible];
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
    guest.hidden = YES;
}
@end
