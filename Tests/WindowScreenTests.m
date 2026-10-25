#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
// Exercise the production hooks explicitly, without guest launch constructors.
#import "../TweakLoader/WindowScreen.m"
#import "TapSyncTestWindow.h"

@interface LCWindowScreenStartupState : LCWindowScreenState
@property(nonatomic) NSUInteger refreshes;
@end
@implementation LCWindowScreenStartupState
- (void)refreshFromScenes:(NSSet<UIScene *> *)scenes {
    NSAssert(NSThread.isMainThread, @"Background screen reads must not enumerate UIKit scenes");
    self.refreshes++;
}
@end

@interface LCWindowScreenTestSession : NSObject
@property(nonatomic, copy) UISceneSessionRole role;
@end
@implementation LCWindowScreenTestSession
@end

// Do not create another real scene from the host's session: UIKit would detach
// its existing window. Stub only the enumeration and scene geometry.
@interface LCWindowScreenTestScene : NSObject
@property(nonatomic, strong) UIScreen *screen;
@property(nonatomic, strong) LCWindowScreenTestSession *session;
@property(nonatomic, strong) id delegate;
@property(nonatomic, copy) NSArray<UIWindow *> *windows;
@property(nonatomic, strong) id<UICoordinateSpace> coordinateSpace;
@property(nonatomic) UIInterfaceOrientation interfaceOrientation;
@end
@implementation LCWindowScreenTestScene
- (BOOL)isKindOfClass:(Class)cls { return cls == UIWindowScene.class || [super isKindOfClass:cls]; }
@end

@interface LCWindowScreenTestDelegate : NSObject
@property(nonatomic, strong) UIWindow *window;
@end
@implementation LCWindowScreenTestDelegate
@end

@interface LCWindowScreenTestWindow : NSObject
@property(nonatomic, weak) UIWindowScene *windowScene;
@property(nonatomic) CGRect bounds;
@property(nonatomic) UIWindowLevel windowLevel;
@property(nonatomic, strong) UIViewController *rootViewController;
@property(nonatomic) BOOL hidden;
@end
@implementation LCWindowScreenTestWindow
@end

@interface WindowScreenTests : XCTestCase<WKNavigationDelegate>
@property(nonatomic, strong) LCWindowScreenState *state;
@property(nonatomic, strong) NSMutableArray<UIWindow *> *windows;
@property(nonatomic, strong) XCTestExpectation *webLoaded;
@end
@implementation WindowScreenTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    LCWindowScreenInstall(@{});
    LCWindowScreenCurrentState = nil;
    self.windows = [NSMutableArray array];
}
- (void)tearDown {
    LCWindowScreenCurrentState = nil;
    self.state = nil;
    for (UIWindow *window in self.windows) {
        [window.rootViewController dismissViewControllerAnimated:NO completion:nil];
        window.hidden = YES;
        window.windowScene = nil;
        window.rootViewController = nil;
    }
    UIWindow *host = LCTapSyncTestHostWindow();
    [host makeKeyWindow];
    XCTestExpectation *settled = [self expectationWithDescription:@"screen hooks and auxiliary windows reset"];
    dispatch_async(dispatch_get_main_queue(), ^{ [host layoutIfNeeded]; [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:5];
    self.webLoaded = nil;
    [super tearDown];
}
- (void)useState:(LCWindowScreenState *)state {
    state.originalOrientedSpace = [LCWindowScreenMainScreen lc_windowScreen_coordinateSpace];
    state.orientedSpace = [LCWindowScreenCoordinateSpace new];
    state.orientedSpace.state = state;
    state.fixedSpace = [LCWindowScreenCoordinateSpace new];
    state.fixedSpace.state = state;
    state.fixedSpace.fixed = YES;
    self.state = state;
    LCWindowScreenCurrentState = state;
}
- (UIWindow *)gameWindowWithSize:(CGSize)size {
    UIWindowScene *scene = LCTapSyncTestHostWindow().windowScene;
    XCTAssertNotNil(scene);
    LCWindowScreenCurrentState = nil;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = (CGRect){CGPointZero, size};
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.backgroundColor = UIColor.whiteColor;
    window.hidden = NO;
    [window layoutIfNeeded];
    [self.windows addObject:window];
    LCWindowScreenState *state = [[LCWindowScreenState alloc] initWithSize:size];
    state.scene = scene;
    state.window = window;
    state.hasBoundWindow = YES;
    [self useState:state];
    XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, size));
    return window;
}
- (LCWindowScreenTestScene *)sceneWithSize:(CGSize)size orientation:(UIInterfaceOrientation)orientation {
    LCWindowScreenTestScene *scene = [LCWindowScreenTestScene new];
    scene.screen = LCWindowScreenMainScreen;
    scene.session = [LCWindowScreenTestSession new];
    scene.session.role = UISceneSessionRoleApplication;
    scene.coordinateSpace = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, size}];
    scene.interfaceOrientation = orientation;
    scene.windows = @[];
    return scene;
}
- (UIWindow *)windowInScene:(LCWindowScreenTestScene *)scene size:(CGSize)size {
    LCWindowScreenTestWindow *window = [LCWindowScreenTestWindow new];
    window.bounds = (CGRect){CGPointZero, size};
    window.windowScene = (UIWindowScene *)scene;
    window.rootViewController = [UIViewController new];
    return (UIWindow *)window;
}
- (void)testCompatibilityRequiresExplicitGuestVirtualWindowOptIn {
    NSDictionary *enabled = @{@"LCUseWindowScreenSize": @YES};
    NSDictionary *virtual = @{@"virtualWindow": @YES};
    XCTAssertTrue(LCWindowScreenShouldEnable(YES, @"game", enabled, virtual));
    XCTAssertFalse(LCWindowScreenShouldEnable(NO, @"game", enabled, virtual));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, nil, enabled, virtual));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, @"game", @{}, virtual));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, @"game", enabled, nil));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, @"game", enabled, @{@"virtualWindow": @NO}));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, @"game", enabled, @{@"virtualWindow": @"YES"}));
    XCTAssertFalse(LCWindowScreenShouldEnable(YES, @"game", @{@"LCUseWindowScreenSize": @YES, @"dontInjectTweakLoader": @YES}, virtual));
    CGRect original = [UIScreen.mainScreen lc_windowScreen_bounds];
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, original));
    XCTAssertEqual(UIScreen.mainScreen.coordinateSpace, [UIScreen.mainScreen lc_windowScreen_coordinateSpace]);
    XCTAssertNil(LCWindowScreenStateForScreen((UIScreen *)[NSObject new]));
}
- (void)testStartupAndNativeDimensionsAreConsistentBeforeGameWindowExists {
    CGFloat scale = UIScreen.mainScreen.scale, nativeScale = UIScreen.mainScreen.nativeScale;
    UIInterfaceOrientation sceneOrientation = LCTapSyncTestHostWindow().windowScene.interfaceOrientation;
    [self useState:[[LCWindowScreenStartupState alloc] initWithSize:CGSizeMake(300, 500)]];
    CGRect screen = UIScreen.mainScreen.bounds;
    XCTAssertTrue(CGRectEqualToRect(screen, CGRectMake(0, 0, 300, 500)));
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.coordinateSpace.bounds, screen));
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.fixedCoordinateSpace.bounds, screen));
    // After swizzling the lc_* selector calls the original. The public selector
    // must return the local size while scale and real UIKit orientation persist.
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.nativeBounds,
                                   CGRectMake(0, 0, round(300 * nativeScale), round(500 * nativeScale))));
    XCTAssertEqual(UIScreen.mainScreen.scale, scale);
    XCTAssertEqual(UIScreen.mainScreen.nativeScale, nativeScale);
    XCTAssertEqual(LCTapSyncTestHostWindow().windowScene.interfaceOrientation, sceneOrientation);
}
- (void)testInvalidStartupGeometryFallsBackToPhysicalScreen {
    CGRect original = [UIScreen.mainScreen lc_windowScreen_bounds];
    CGSize invalid[] = {{0, 0}, {-1, 500}, {300, NAN}, {INFINITY, 500}};
    for (NSUInteger i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        [self useState:[[LCWindowScreenStartupState alloc] initWithSize:invalid[i]]];
        XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, original));
        XCTAssertEqual(UIScreen.mainScreen.coordinateSpace, [UIScreen.mainScreen lc_windowScreen_coordinateSpace]);
    }
}
- (void)testPortraitGameInLandscapeSceneKeepsItsOwnShapeAndScale {
    LCWindowScreenTestScene *scene = [self sceneWithSize:CGSizeMake(1024, 768) orientation:UIInterfaceOrientationLandscapeLeft];
    UIWindow *game = [self windowInScene:scene size:CGSizeMake(280, 680)];
    LCWindowScreenTestDelegate *delegate = [LCWindowScreenTestDelegate new];
    delegate.window = game;
    scene.delegate = delegate;
    scene.windows = @[game];
    LCWindowScreenState *state = [[LCWindowScreenState alloc] initWithSize:CGSizeMake(480, 320)];
    [state refreshFromScenes:(id)[NSSet setWithObject:scene]];
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(280, 680)));
    XCTAssertEqual(state.readSnapshot.orientation, UIInterfaceOrientationPortrait);
    // Guest points already incorporate the host's content scale. Do not divide
    // them again, or use the decorative window/frame in device pixels.
    game.bounds = CGRectMake(0, 0, 560, 1360);
    [state refreshFromScenes:(id)[NSSet setWithObject:scene]];
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(560, 1360)));
    XCTAssertEqual(scene.interfaceOrientation, UIInterfaceOrientationLandscapeLeft);
}
- (void)testPopupBecomingKeyDoesNotReplaceHiddenGameGeometry {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    game.hidden = YES;
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    ad.rootViewController = [UIViewController new];
    ad.frame = CGRectMake(0, 0, 1024, 768);
    ad.windowLevel = UIWindowLevelAlert;
    [ad makeKeyAndVisible];
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 300, 500)));
    XCTAssertEqual(self.state.window, game);
    ad.windowLevel = UIWindowLevelNormal;
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 300, 500)));
    ad.hidden = YES;
    game.hidden = NO;
    game.frame = CGRectMake(0, 0, 600, 400);
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 600, 400)));
}
- (void)testWindowResizeRefreshesSnapshotForBackgroundSDKReads {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    game.frame = CGRectMake(0, 0, 600, 400);
    LCWindowScreenStartupState *state = [[LCWindowScreenStartupState alloc] initWithSize:self.state.readSnapshot.size];
    [self useState:state];
    XCTestExpectation *read = [self expectationWithDescription:@"background screen read uses the last geometry"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 600, 400)));
        XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.coordinateSpace.bounds, CGRectMake(0, 0, 600, 400)));
        [read fulfill];
    });
    [self waitForExpectations:@[read] timeout:5];
}
- (void)testSceneSelectionIgnoresExternalAndNonApplicationScenesAndAmbiguity {
    LCWindowScreenState *state = [[LCWindowScreenState alloc] initWithSize:CGSizeMake(300, 500)];
    LCWindowScreenTestScene *external = [self sceneWithSize:CGSizeMake(1920, 1080) orientation:UIInterfaceOrientationLandscapeRight];
    external.screen = (id)[NSObject new];
    LCWindowScreenTestScene *keyboard = [self sceneWithSize:CGSizeMake(1024, 768) orientation:UIInterfaceOrientationLandscapeRight];
    keyboard.session.role = @"keyboard";
    [state refreshFromScenes:(id)[NSSet setWithObjects:external, keyboard, nil]];
    XCTAssertNil(state.scene);
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(300, 500)));
    LCWindowScreenTestScene *first = [self sceneWithSize:CGSizeMake(320, 500) orientation:UIInterfaceOrientationPortrait];
    LCWindowScreenTestScene *second = [self sceneWithSize:CGSizeMake(600, 400) orientation:UIInterfaceOrientationLandscapeLeft];
    [state refreshFromScenes:(id)[NSSet setWithObjects:first, second, nil]];
    XCTAssertNil(state.scene);
    [state refreshFromScenes:(id)[NSSet setWithObjects:first, external, keyboard, nil]];
    XCTAssertEqual((id)state.scene, first);
}
- (void)testDisconnectionRetainsLastSizeAndDoesNotAdoptOversizedReplacementAd {
    LCWindowScreenTestScene *scene = [self sceneWithSize:CGSizeMake(300, 500) orientation:UIInterfaceOrientationPortrait];
    UIWindow *game = [self windowInScene:scene size:CGSizeMake(300, 500)];
    LCWindowScreenTestDelegate *delegate = [LCWindowScreenTestDelegate new];
    delegate.window = game;
    scene.delegate = delegate;
    scene.windows = @[game];
    LCWindowScreenState *state = [[LCWindowScreenState alloc] initWithSize:CGSizeZero];
    [state refreshFromScenes:(id)[NSSet setWithObject:scene]];
    delegate.window = nil;
    game.windowScene = nil;
    UIWindow *ad = [self windowInScene:scene size:CGSizeMake(1024, 768)];
    scene.windows = @[ad];
    [state refreshFromScenes:(id)[NSSet setWithObject:scene]];
    XCTAssertNil(state.window);
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(300, 500)));
    [state refreshFromScenes:[NSSet set]];
    XCTAssertNil(state.scene);
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(300, 500)));
    LCWindowScreenTestScene *replacement = [self sceneWithSize:CGSizeMake(500, 300) orientation:UIInterfaceOrientationLandscapeRight];
    delegate.window = [self windowInScene:replacement size:CGSizeMake(500, 300)];
    replacement.delegate = delegate;
    replacement.windows = @[delegate.window];
    [state refreshFromScenes:(id)[NSSet setWithObject:replacement]];
    XCTAssertTrue(CGSizeEqualToSize(state.readSnapshot.size, CGSizeMake(500, 300)));
}
- (void)testFixedScreenCoordinatesRotateAndRoundTripInEveryOrientation {
    UIInterfaceOrientation orientations[] = {UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown,
                                            UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight};
    for (NSUInteger i = 0; i < 4; i++) {
        UIInterfaceOrientation orientation = orientations[i];
        CGSize size = UIInterfaceOrientationIsLandscape(orientation) ? CGSizeMake(500, 300) : CGSizeMake(300, 500);
        LCWindowScreenStartupState *state = [[LCWindowScreenStartupState alloc] initWithSize:size];
        state.snapshot = (LCWindowScreenSnapshot){size, orientation};
        [self useState:state];
        XCTAssertTrue(CGRectEqualToRect(state.fixedSpace.bounds, CGRectMake(0, 0, 300, 500)));
        CGPoint point = CGPointMake(30, 70);
        CGPoint expected[] = {{30, 70}, {270, 430}, {430, 30}, {70, 270}};
        CGPoint mapped = [state.fixedSpace convertPoint:point toCoordinateSpace:state.orientedSpace];
        XCTAssertTrue(CGPointEqualToPoint(mapped, expected[i]));
        XCTAssertTrue(CGPointEqualToPoint([state.orientedSpace convertPoint:mapped toCoordinateSpace:state.fixedSpace], point));
        XCTAssertTrue(CGPointEqualToPoint([state.orientedSpace convertPoint:point fromCoordinateSpace:state.fixedSpace], expected[i]));
        CGRect rect = CGRectMake(10, 20, 80, 120);
        CGRect converted = [state.fixedSpace convertRect:rect toCoordinateSpace:state.orientedSpace];
        XCTAssertTrue(CGRectEqualToRect([state.orientedSpace convertRect:converted toCoordinateSpace:state.fixedSpace], rect));
        XCTAssertTrue(CGRectEqualToRect([state.fixedSpace convertRect:state.fixedSpace.bounds toCoordinateSpace:state.orientedSpace], UIScreen.mainScreen.bounds));
        XCTAssertTrue(CGRectIsNull([state.fixedSpace convertRect:CGRectNull toCoordinateSpace:state.orientedSpace]));
    }
}
- (void)testUIKitViewConversionsAndHitTargetsUseGuestPoints {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    game.bounds = CGRectMake(13, 21, 300, 500);
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(23, 41, 100, 80)];
    [game addSubview:view];
    CGPoint screenPoint = CGPointMake(10, 20);
    CGPoint windowPoint = [UIScreen.mainScreen convertPoint:screenPoint toCoordinateSpace:game];
    XCTAssertTrue(CGPointEqualToPoint(windowPoint, CGPointMake(23, 41)));
    XCTAssertTrue(CGPointEqualToPoint([UIScreen.mainScreen.coordinateSpace convertPoint:screenPoint toCoordinateSpace:view], CGPointZero));
    XCTAssertTrue(CGPointEqualToPoint([UIScreen.mainScreen convertPoint:windowPoint fromCoordinateSpace:game], screenPoint));
    XCTAssertTrue(CGPointEqualToPoint([game convertPoint:windowPoint toCoordinateSpace:UIScreen.mainScreen.coordinateSpace], screenPoint));
    CGRect local = [UIScreen.mainScreen.coordinateSpace convertRect:UIScreen.mainScreen.bounds toCoordinateSpace:game];
    XCTAssertTrue(CGRectEqualToRect(local, game.bounds));
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    ad.frame = CGRectMake(0, 0, 1024, 768);
    CGPoint adPoint = [UIScreen.mainScreen.coordinateSpace convertPoint:CGPointMake(40, 60) toCoordinateSpace:ad];
    XCTAssertTrue(CGPointEqualToPoint([UIScreen.mainScreen.coordinateSpace convertPoint:adPoint fromCoordinateSpace:ad], CGPointMake(40, 60)));
    XCTAssertEqual([game hitTest:CGPointMake(24, 42) withEvent:nil], view);
}
- (void)testFullScreenModalAndCloseButtonFitTheGameWindow {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    [game makeKeyWindow];
    UIViewController *modal = [UIViewController new];
    modal.modalPresentationStyle = UIModalPresentationFullScreen;
    modal.view.backgroundColor = UIColor.blueColor;
    XCTestExpectation *presented = [self expectationWithDescription:@"game modal presented"];
    [game.rootViewController presentViewController:modal animated:NO completion:^{ [presented fulfill]; }];
    [self waitForExpectations:@[presented] timeout:5];
    [game layoutIfNeeded];
    XCTAssertTrue(CGSizeEqualToSize(modal.view.bounds.size, game.bounds.size));
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(CGRectGetWidth(UIScreen.mainScreen.bounds) - 44, 0, 44, 44);
    [modal.view addSubview:close];
    XCTAssertTrue(CGRectContainsRect(modal.view.bounds, close.frame));
    CGPoint hit = [close convertPoint:CGPointMake(22, 22) toView:game];
    XCTAssertEqual([game hitTest:hit withEvent:nil], close);
}
- (void)testResponsiveWebPopupKeepsItsViewportInsideGameBounds {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:game.bounds];
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    self.webLoaded = [self expectationWithDescription:@"responsive popup loaded"];
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}#close{position:fixed;right:0;top:0;width:44px;height:44px}</style><button id='close'>X</button>" baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    XCTestExpectation *evaluated = [self expectationWithDescription:@"web popup dimensions read"];
    [web evaluateJavaScript:@"({width:innerWidth,height:innerHeight,right:document.getElementById('close').getBoundingClientRect().right,screenWidth:screen.width,screenHeight:screen.height})"
         completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualWithAccuracy([result[@"width"] doubleValue], 300, 1);
        XCTAssertEqualWithAccuracy([result[@"height"] doubleValue], 500, 1);
        XCTAssertLessThanOrEqual([result[@"right"] doubleValue], 300);
        // WebKit's screen.* belongs to its separate web process. Record it,
        // without claiming a UIScreen hook rewrites JavaScript/device orientation.
        XCTAttachment *attachment = [XCTAttachment attachmentWithString:[result description]];
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self.webLoaded fulfill]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    XCTFail(@"Web popup initial load failed: %@", error);
    [self.webLoaded fulfill];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    XCTFail(@"Web popup load failed: %@", error);
    [self.webLoaded fulfill];
}
@end
