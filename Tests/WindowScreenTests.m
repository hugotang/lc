#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
// Exercise the production hooks explicitly, without guest launch constructors.
#import "../TweakLoader/WindowScreen.m"
#import "../MultitaskSupport/WorkspaceLaunchLayout.h"
#import "../MultitaskSupport/WindowGridLayout.h"
#import "../MultitaskSupport/WindowChromeLayout.h"
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
@property(nonatomic, getter=isHidden) BOOL hidden;
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
    state.originalOrientedSpace = UIScreen.mainScreen.coordinateSpace;
    state.originalFixedSpace = UIScreen.mainScreen.fixedCoordinateSpace;
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
    scene.session.role = UIWindowSceneSessionRoleApplication;
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
    XCTAssertEqual(UIScreen.mainScreen.coordinateSpace, self.state.originalOrientedSpace ?: UIScreen.mainScreen.coordinateSpace);
    XCTAssertNil(LCWindowScreenStateForScreen((UIScreen *)[NSObject new], __builtin_return_address(0)));
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
        XCTAssertEqual(UIScreen.mainScreen.coordinateSpace, self.state.originalOrientedSpace ?: UIScreen.mainScreen.coordinateSpace);
    }
}
- (void)checkWorkspaceLaunchWithHiddenBar:(BOOL)hidden scale:(CGFloat)scale singleRow:(BOOL)singleRow {
    NSMutableArray<LCWorkspaceWindow *> *entries = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSUInteger index = 0; index < 4; index++) {
        [entries addObject:[[LCWorkspaceWindow alloc] initWithBundleName:@"game.app"
            dataUUID:[NSString stringWithFormat:@"account-%lu", (unsigned long)index] scale:scale]];
        [views addObject:[UIView new]];
    }
    LCWindowWorkspace *workspace = [[LCWindowWorkspace alloc] initWithWindows:entries proportions:@{}
                                                      singleRowInLandscape:singleRow];
    LCWorkspaceLaunchLayout *plan = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:workspace];
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1366, 1024)];
    [LCTapSyncTestHostWindow().rootViewController.view addSubview:host];
    LCWindowGridLayout grid = LCWindowGridLayoutMakeForOrientation(4, 1366, 1024, 2, 88, false, singleRow);
    CGSize expected = CGSizeZero;
    // The third and fourth accounts start after only part of the workspace exists.
    NSArray *orders = @[@[@0, @1, @2, @3], @[@3, @1, @0, @2]];
    for (NSArray<NSNumber *> *order in orders) {
        NSMutableArray<UIView *> *opened = [NSMutableArray array];
        for (NSNumber *number in order) {
            NSUInteger account = number.unsignedIntegerValue;
            [opened addObject:views[account]];
            NSArray *slots = [plan slotsForWindows:opened matchingEntry:^BOOL(id view, LCWorkspaceWindow *entry) {
                return views[[entries indexOfObjectIdenticalTo:entry]] == view;
            }];
            XCTAssertEqual(slots.count, 4);
            NSUInteger slot = [slots indexOfObjectIdenticalTo:views[account]];
            XCTAssertEqual(slot, account);
            LCWindowGridRect tile = LCWindowGridFrameWithDividers(grid, slot, NULL, NULL, NULL);
            UIStackView *container = [[UIStackView alloc] initWithFrame:CGRectMake(tile.x, tile.y, tile.width, tile.height)];
            container.axis = UILayoutConstraintAxisVertical;
            [container addArrangedSubview:[UIView new]];
            UIView *guest = [UIView new];
            [container insertSubview:guest atIndex:0];
            [host addSubview:container];
            UINavigationBar *bar = [UINavigationBar new];
            bar.items = @[[[UINavigationItem alloc] initWithTitle:@"Account"]];
            LCWindowChromeLayout *chrome = [LCWindowChromeLayout new];
            [chrome applyToContainer:container guest:guest bar:bar bottom:account >= 2 hidden:hidden overlay:NO];
            [container layoutIfNeeded];
            LCWorkspaceWindow *entry = [plan entryForBundleName:@"game.app" dataUUID:entries[account].dataUUID];
            CGSize startup = CGSizeMake(guest.bounds.size.width / entry.scale, guest.bounds.size.height / entry.scale);
            [self useState:[[LCWindowScreenStartupState alloc] initWithSize:startup]];
            CGSize screen = UIScreen.mainScreen.bounds.size;
            XCTAssertEqualWithAccuracy(screen.width, tile.width / scale, 0.01);
            XCTAssertEqualWithAccuracy(screen.height, (tile.height - (hidden ? 0 : 44)) / scale, 0.01);
            if (CGSizeEqualToSize(expected, CGSizeZero)) expected = screen;
            XCTAssertTrue(CGSizeEqualToSize(screen, expected));
            XCTAssertEqual(UIInterfaceOrientationIsLandscape(self.state.readSnapshot.orientation), screen.width > screen.height);
            [container removeFromSuperview];
        }
    }
    LCWindowScreenCurrentState = nil;
    [host removeFromSuperview];
}
- (void)testFourAccountWorkspaceLaunchHasEqualPortraitContentBeforeConstructors {
    [self checkWorkspaceLaunchWithHiddenBar:YES scale:1 singleRow:YES];
}
- (void)testWorkspaceLaunchUsesSavedScaleWithVisibleTopAndBottomBars {
    [self checkWorkspaceLaunchWithHiddenBar:NO scale:0.5 singleRow:YES];
    [self checkWorkspaceLaunchWithHiddenBar:NO scale:2 singleRow:YES];
}
- (void)testAutomaticGridLaunchKeepsEqualThirdAndFourthGameDimensions {
    [self checkWorkspaceLaunchWithHiddenBar:YES scale:1 singleRow:NO];
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
- (void)testFixedAndNativeDimensionsFollowLocalShapeWithoutReplacingUIKitSpaces {
    UIInterfaceOrientation orientations[] = {UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown,
                                            UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight};
    id<UICoordinateSpace> oriented = UIScreen.mainScreen.coordinateSpace;
    id<UICoordinateSpace> fixed = UIScreen.mainScreen.fixedCoordinateSpace;
    CGPoint point = CGPointMake(30, 70);
    CGPoint convertedBefore = [fixed convertPoint:point toCoordinateSpace:oriented];
    for (NSUInteger i = 0; i < 4; i++) {
        UIInterfaceOrientation orientation = orientations[i];
        CGSize size = UIInterfaceOrientationIsLandscape(orientation) ? CGSizeMake(500, 300) : CGSizeMake(300, 500);
        LCWindowScreenStartupState *state = [[LCWindowScreenStartupState alloc] initWithSize:size];
        state.snapshot = (LCWindowScreenSnapshot){size, orientation};
        [self useState:state];
        XCTAssertEqual(UIScreen.mainScreen.coordinateSpace, oriented);
        XCTAssertEqual(UIScreen.mainScreen.fixedCoordinateSpace, fixed);
        XCTAssertTrue(CGRectEqualToRect(fixed.bounds, CGRectMake(0, 0, 300, 500)));
        XCTAssertTrue(CGRectEqualToRect(oriented.bounds, (CGRect){CGPointZero, size}));
        CGPoint mapped = [fixed convertPoint:point toCoordinateSpace:oriented];
        XCTAssertTrue(CGPointEqualToPoint(mapped, convertedBefore));
        XCTAssertTrue(CGPointEqualToPoint([oriented convertPoint:mapped toCoordinateSpace:fixed], point));
        CGRect rect = CGRectMake(10, 20, 80, 120);
        CGRect converted = [fixed convertRect:rect toCoordinateSpace:oriented];
        XCTAssertTrue(CGRectEqualToRect([oriented convertRect:converted toCoordinateSpace:fixed], rect));
        XCTAssertTrue(CGRectIsNull([fixed convertRect:CGRectNull toCoordinateSpace:oriented]));
    }
}
- (void)testSystemCallersAndNestedGeometryQueriesKeepPhysicalDimensions {
    [self useState:[[LCWindowScreenStartupState alloc] initWithSize:CGSizeMake(300, 500)]];
    IMP system = method_getImplementation(class_getInstanceMethod(UIWindowScene.class, @selector(interfaceOrientation)));
    XCTAssertTrue(LCWindowScreenCallerUsesPhysicalGeometry((const void *)system));
    XCTAssertNil(LCWindowScreenStateForScreen(UIScreen.mainScreen, (const void *)system));
    XCTAssertTrue(LCWindowScreenCallerUsesPhysicalGeometry(NULL));
    CGRect original = [UIScreen.mainScreen lc_windowScreen_bounds];
    LCWindowScreenQueryDepth++;
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, original));
    LCWindowScreenQueryDepth--;
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 300, 500)));
}
- (void)testUIKitViewAndOtherWindowConversionsRemainUnchanged {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    LCWindowScreenState *state = self.state;
    LCWindowScreenCurrentState = nil;
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(23, 41, 100, 80)];
    [game addSubview:view];
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    ad.frame = CGRectMake(0, 0, 1024, 768);
    id<UICoordinateSpace> oriented = UIScreen.mainScreen.coordinateSpace;
    id<UICoordinateSpace> fixed = UIScreen.mainScreen.fixedCoordinateSpace;
    CGPoint point = CGPointMake(40, 60);
    CGPoint toView = [oriented convertPoint:point toCoordinateSpace:view];
    CGPoint toAd = [fixed convertPoint:point toCoordinateSpace:ad];
    CGRect gameInScreen = [oriented convertRect:game.bounds fromCoordinateSpace:game];
    LCWindowScreenCurrentState = state;
    XCTAssertTrue(CGPointEqualToPoint([oriented convertPoint:point toCoordinateSpace:view], toView));
    XCTAssertTrue(CGPointEqualToPoint([fixed convertPoint:point toCoordinateSpace:ad], toAd));
    XCTAssertTrue(CGPointEqualToPoint([oriented convertPoint:toView fromCoordinateSpace:view], point));
    XCTAssertTrue(CGPointEqualToPoint([fixed convertPoint:toAd fromCoordinateSpace:ad], point));
    XCTAssertTrue(CGRectEqualToRect([oriented convertRect:game.bounds fromCoordinateSpace:game], gameInScreen));
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
        // WebKit's automatic scroll insets exclude the scene's status/home
        // safe area from the CSS viewport, even though its UIView fills the game.
        UIEdgeInsets insets = web.scrollView.adjustedContentInset;
        CGFloat viewportWidth = web.bounds.size.width - insets.left - insets.right;
        CGFloat viewportHeight = web.bounds.size.height - insets.top - insets.bottom;
        XCTAssertTrue(CGRectContainsRect(game.bounds, web.frame));
        XCTAssertEqualWithAccuracy([result[@"width"] doubleValue], viewportWidth, 1);
        XCTAssertEqualWithAccuracy([result[@"height"] doubleValue], viewportHeight, 1);
        XCTAssertLessThanOrEqual([result[@"right"] doubleValue], viewportWidth);
        XCTAssertLessThanOrEqual([result[@"height"] doubleValue], game.bounds.size.height);
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
