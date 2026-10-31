#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
// Exercise the production hooks explicitly, without guest launch constructors.
#import "../TweakLoader/WindowScreen.m"
#import "../MultitaskSupport/WorkspaceLaunchLayout.h"
#import "../MultitaskSupport/WindowGridLayout.h"
#import "../MultitaskSupport/WindowChromeLayout.h"
#import "../MultitaskSupport/WindowContentGeometry.h"
#import "../TweakLoader/WindowGeometryDiagnostics.h"
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

// A real non-null protocol object for forwarding through UIViewController's
// implementation. No animation or interaction is in progress in this fixture.
@interface LCWindowScreenTestCoordinator : NSObject<UIViewControllerTransitionCoordinator>
@property(nonatomic, strong) UIView *containerView;
@end
@implementation LCWindowScreenTestCoordinator
- (BOOL)isAnimated { return NO; }
- (UIModalPresentationStyle)presentationStyle { return UIModalPresentationNone; }
- (BOOL)initiallyInteractive { return NO; }
- (BOOL)isInteractive { return NO; }
- (BOOL)isCancelled { return NO; }
- (BOOL)isInterruptible { return YES; }
- (NSTimeInterval)transitionDuration { return 0; }
- (CGFloat)percentComplete { return 1; }
- (CGFloat)completionVelocity { return 0; }
- (UIViewAnimationCurve)completionCurve { return UIViewAnimationCurveLinear; }
- (CGAffineTransform)targetTransform { return CGAffineTransformIdentity; }
- (UIViewController *)viewControllerForKey:(UITransitionContextViewControllerKey)key { return nil; }
- (UIView *)viewForKey:(UITransitionContextViewKey)key { return nil; }
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion { return NO; }
- (BOOL)animateAlongsideTransitionInView:(UIView *)view
                              animation:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                             completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion { return NO; }
- (void)notifyWhenInteractionEndsUsingBlock:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))handler {}
- (void)notifyWhenInteractionChangesUsingBlock:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))handler {}
@end

// Model an app that rebuilds screen-based layout in its UIKit transition
// override, before calling super while its window still has the old bounds.
@interface LCWindowScreenTransitionController : UIViewController
@property(nonatomic) CGRect screenBeforeSuper, screenAfterSuper, nativeDuringTransition;
@property(nonatomic) CGRect orientedDuringTransition, fixedDuringTransition, applicationDuringTransition;
@property(nonatomic) CGRect originalSystemBounds, backgroundDuringTransition;
@property(nonatomic) CGSize receivedSize, actualWindowSizeDuringTransition;
@property(nonatomic, strong) id<UIViewControllerTransitionCoordinator> receivedCoordinator;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL throwsOnTransition;
@property(nonatomic) BOOL skipsSuper;
@property(nonatomic, copy) dispatch_block_t duringTransition;
@end
@implementation LCWindowScreenTransitionController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    self.calls++;
    self.receivedSize = size;
    self.receivedCoordinator = coordinator;
    self.actualWindowSizeDuringTransition = self.viewIfLoaded.window.bounds.size;
    self.screenBeforeSuper = UIScreen.mainScreen.bounds;
    self.nativeDuringTransition = UIScreen.mainScreen.nativeBounds;
    self.orientedDuringTransition = UIScreen.mainScreen.coordinateSpace.bounds;
    self.fixedDuringTransition = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    // Intentionally cover the legacy API supported by the compatibility hook.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    self.applicationDuringTransition = UIScreen.mainScreen.applicationFrame;
#pragma clang diagnostic pop
    self.originalSystemBounds = [UIScreen.mainScreen lc_windowScreen_bounds];
    __block CGRect background;
    // dispatch_sync to a global queue may execute inline on the main thread.
    // Dispatch asynchronously and wait here so this actually exercises a
    // background snapshot during the still-active root callback.
    dispatch_semaphore_t read = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSCAssert(!NSThread.isMainThread, @"The background fixture must use another thread");
        background = UIScreen.mainScreen.bounds;
        dispatch_semaphore_signal(read);
    });
    NSAssert(dispatch_semaphore_wait(read, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
             @"Background screen reads cannot wait for the main thread");
    self.backgroundDuringTransition = background;
    if (self.duringTransition) self.duringTransition();
    if (self.throwsOnTransition) @throw [NSException exceptionWithName:@"LCWindowScreenTestException" reason:nil userInfo:nil];
    if (!self.skipsSuper) [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    self.screenAfterSuper = UIScreen.mainScreen.bounds;
}
@end

@interface LCWindowScreenInheritedTransitionController : LCWindowScreenTransitionController
@end
@implementation LCWindowScreenInheritedTransitionController
@end

@interface WindowScreenTests : XCTestCase<WKNavigationDelegate>
@property(nonatomic, strong) LCWindowScreenState *state;
@property(nonatomic, strong) NSMutableArray<UIWindow *> *windows;
@property(nonatomic, strong) XCTestExpectation *webLoaded;
- (void)checkWorkspaceLaunchWithHiddenBar:(BOOL)hidden scale:(CGFloat)scale singleRow:(BOOL)singleRow
                           landscapeTop:(BOOL)top landscapeBottom:(BOOL)bottom;
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
    [self checkWorkspaceLaunchWithHiddenBar:hidden scale:scale singleRow:singleRow landscapeTop:YES landscapeBottom:NO];
}
- (void)checkWorkspaceLaunchWithHiddenBar:(BOOL)hidden scale:(CGFloat)scale singleRow:(BOOL)singleRow
                           landscapeTop:(BOOL)top landscapeBottom:(BOOL)bottom {
    NSMutableArray<LCWorkspaceWindow *> *entries = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSUInteger index = 0; index < 4; index++) {
        [entries addObject:[[LCWorkspaceWindow alloc] initWithBundleName:@"game.app"
            dataUUID:[NSString stringWithFormat:@"account-%lu", (unsigned long)index] scale:scale]];
        [views addObject:[UIView new]];
    }
    LCWindowWorkspace *saved = [[LCWindowWorkspace alloc] initWithWindows:entries proportions:@{}
        singleRowInLandscape:singleRow reservePortraitTop:NO reservePortraitBottom:YES
        reserveLandscapeTop:top reserveLandscapeBottom:bottom];
    LCWindowWorkspace *workspace = [[LCWindowWorkspace alloc] initWithPropertyList:saved.propertyList];
    LCWorkspaceLaunchLayout *plan = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:workspace];
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1366, 1024)];
    [LCTapSyncTestHostWindow().rootViewController.view addSubview:host];
    LCWindowGridRect content = LCWindowGridContentBoundsWithReservedAreas((LCWindowGridRect){0, 0, 1366, 1024},
        (LCWindowGridRect){0, 24, 1366, 980}, workspace.reservePortraitTop, workspace.reservePortraitBottom,
        workspace.reserveLandscapeTop, workspace.reserveLandscapeBottom);
    LCWindowGridLayout grid = LCWindowGridLayoutMakeForOrientation(4, content.width, content.height, 2, 88,
                                                                 false, workspace.singleRowInLandscape);
    CGFloat expectedContentHeight = 1024 - (top ? 24 : 0) - (bottom ? 20 : 0);
    CGFloat expectedTileHeight = singleRow ? expectedContentHeight : (expectedContentHeight - 2) / 2;
    XCTAssertEqualWithAccuracy(content.y, top ? 24 : 0, 0.01);
    XCTAssertEqualWithAccuracy(content.height, expectedContentHeight, 0.01);
    CGSize expected = CGSizeZero;
    // The third and fourth accounts start after only part of the workspace exists.
    NSArray *orders = @[@[@0, @1, @2, @3], @[@3, @1, @0, @2]];
    for (NSArray<NSNumber *> *order in orders) {
        NSMutableArray<UIView *> *opened = [NSMutableArray array];
        for (NSNumber *number in order) {
            NSUInteger account = number.unsignedIntegerValue;
            [opened addObject:views[account]];
            NSArray *slots = [plan slotsForWindows:opened matchingEntry:^BOOL(id view, LCWorkspaceWindow *entry) {
                return views[[workspace.windows indexOfObjectIdenticalTo:entry]] == view;
            }];
            XCTAssertEqual(slots.count, 4);
            NSUInteger slot = [slots indexOfObjectIdenticalTo:views[account]];
            XCTAssertEqual(slot, account);
            LCWindowGridRect tile = LCWindowGridFrameWithDividers(grid, slot, NULL, NULL, NULL);
            UIStackView *container = [[UIStackView alloc] initWithFrame:CGRectMake(content.x + tile.x, content.y + tile.y,
                                                                               tile.width, tile.height)];
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
            CGSize startup = LCWindowContentLogicalSize(guest.bounds.size, entry.scale);
            [self useState:[[LCWindowScreenStartupState alloc] initWithSize:startup]];
            CGSize screen = UIScreen.mainScreen.bounds.size;
            XCTAssertEqualWithAccuracy(screen.width, tile.width / scale, 0.01);
            XCTAssertEqualWithAccuracy(screen.height, (tile.height - (hidden ? 0 : 44)) / scale, 0.01);
            XCTAssertEqualWithAccuracy(screen.height, (expectedTileHeight - (hidden ? 0 : 44)) / scale, 0.01);
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
- (void)testLandscapeReservedAreasKeepEqualSingleRowStartupDimensions {
    for (NSUInteger choices = 0; choices < 4; choices++) {
        [self checkWorkspaceLaunchWithHiddenBar:YES scale:1 singleRow:YES
            landscapeTop:(choices & 1) != 0 landscapeBottom:(choices & 2) != 0];
    }
}
- (void)testLandscapeReservedAreasKeepAutomaticGridScaleAndChromeDimensions {
    for (NSUInteger choices = 0; choices < 4; choices++) {
        [self checkWorkspaceLaunchWithHiddenBar:NO scale:0.5 singleRow:NO
            landscapeTop:(choices & 1) != 0 landscapeBottom:(choices & 2) != 0];
        [self checkWorkspaceLaunchWithHiddenBar:NO scale:2 singleRow:NO
            landscapeTop:(choices & 1) != 0 landscapeBottom:(choices & 2) != 0];
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
    XCTestExpectation *read = [self expectationWithDescription:@"background screen read uses the last geometry"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, CGRectMake(0, 0, 600, 400)));
        XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.coordinateSpace.bounds, CGRectMake(0, 0, 600, 400)));
        [read fulfill];
    });
    [self waitForExpectations:@[read] timeout:5];
}
- (void)testRotationReplacesStartupScreenDimensionsWithCurrentGameContent {
    CGSize portrait = LCWindowContentLogicalSize(CGSizeMake(510, 638), 0.5);
    CGSize landscape = LCWindowContentLogicalSize(CGSizeMake(340, 980), 0.5);
    UIWindow *game = [self gameWindowWithSize:portrait];
    [game makeKeyWindow];
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    ad.rootViewController = [UIViewController new];
    [self.windows addObject:ad];
    [ad makeKeyAndVisible];
    for (NSValue *value in @[[NSValue valueWithCGSize:landscape], [NSValue valueWithCGSize:portrait],
                            [NSValue valueWithCGSize:landscape]]) {
        CGSize target = value.CGSizeValue;
        game.bounds = (CGRect){CGPointZero, target};
        [game layoutIfNeeded];
        XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, target));
        XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.coordinateSpace.bounds.size, target));
        XCTAssertTrue(CGSizeEqualToSize(ad.frame.size, game.frame.size));
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(CGRectGetWidth(UIScreen.mainScreen.bounds) - 44, 0, 44, 44);
        [game.rootViewController.view addSubview:close];
        CGPoint hit = [close convertPoint:CGPointMake(22, 22) toView:game];
        XCTAssertTrue(CGRectContainsPoint(game.bounds, hit));
        XCTAssertEqual([game hitTest:hit withEvent:nil], close);
        [close removeFromSuperview];
        XCTAssertEqual(self.state.window, game);
    }
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
        XCTAssertEqualWithAccuracy([result[@"screenWidth"] doubleValue], viewportWidth, 1);
        XCTAssertEqualWithAccuracy([result[@"screenHeight"] doubleValue], viewportHeight, 1);
        XCTAttachment *attachment = [XCTAttachment attachmentWithString:[result description]];
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)testAdWindowCreatedFromSceneStartsWithGuestContentBounds {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    ad.rootViewController = [UIViewController new];
    ad.windowLevel = UIWindowLevelAlert;
    [ad makeKeyAndVisible];
    [ad layoutIfNeeded];
    XCTAssertTrue(CGSizeEqualToSize(ad.bounds.size, game.bounds.size));
    XCTAssertTrue(CGSizeEqualToSize(ad.rootViewController.view.bounds.size, game.bounds.size));
    XCTAssertEqual(self.state.window, game);
}
- (void)testWholeSceneAdTracksGameResizeAndKeepsCloseButtonReachable {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    ad.rootViewController = [UIViewController new];
    ad.windowLevel = UIWindowLevelAlert;
    [ad makeKeyAndVisible];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(256, 0, 44, 44);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [ad.rootViewController.view addSubview:close];
    CGSize sizes[] = {{600, 400}, {280, 680}, {300, 500}};
    for (NSUInteger i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        game.frame = (CGRect){CGPointMake(17, 23), sizes[i]};
        [ad layoutIfNeeded];
        XCTAssertTrue(CGRectEqualToRect(ad.frame, game.frame));
        XCTAssertTrue(CGSizeEqualToSize(ad.bounds.size, game.bounds.size));
        XCTAssertTrue(CGRectContainsRect(ad.rootViewController.view.bounds, close.frame));
        CGPoint hit = [close convertPoint:CGPointMake(22, 22) toView:ad];
        XCTAssertEqual([ad hitTest:hit withEvent:nil], close);
        XCTAssertEqual(self.state.window, game);
    }
}
- (void)testSmallCustomPopupRetainsItsRectangleAfterGameResize {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    UIWindow *popup = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:popup];
    CGRect custom = CGRectMake(20, 40, 180, 140);
    popup.frame = custom;
    popup.rootViewController = [UIViewController new];
    [popup makeKeyAndVisible];
    game.frame = CGRectMake(0, 0, 600, 400);
    XCTAssertTrue(CGRectEqualToRect(popup.frame, custom));
    XCTAssertNil(objc_getAssociatedObject(popup, &LCWindowScreenAdjustedWindowKey));
}
- (void)testLateWholeScreenAdFrameAndBoundsAreRefittedBeforePresentation {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    LCWindowScreenCurrentState = nil;
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:ad];
    LCWindowScreenCurrentState = self.state;
    ad.rootViewController = [UIViewController new];
    CGRect physical = [UIScreen.mainScreen lc_windowScreen_bounds];
    ad.frame = physical;
    XCTAssertTrue(CGRectEqualToRect(ad.frame, game.frame));
    ad.bounds = CGRectMake(0, 0, physical.size.height, physical.size.width);
    XCTAssertTrue(CGSizeEqualToSize(ad.bounds.size, game.bounds.size));
    [ad makeKeyAndVisible];
    XCTAssertTrue(CGSizeEqualToSize(ad.rootViewController.view.bounds.size, game.bounds.size));
}
- (void)testAuxiliaryWindowCorrectionExcludesSystemOtherSceneAndDisabledState {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    LCWindowScreenCurrentState = nil;
    UIWindow *systemWindow = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    [self.windows addObject:systemWindow];
    CGRect physical = [UIScreen.mainScreen lc_windowScreen_bounds];
    XCTAssertTrue(CGRectEqualToRect(LCWindowScreenAuxiliaryFrame(systemWindow, physical, __builtin_return_address(0)), physical));
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    XCTAssertFalse(LCWindowScreenConfigureWebConfiguration(configuration));
    XCTAssertNil(objc_getAssociatedObject(configuration.userContentController, &LCWindowScreenWebScriptKey));
    LCWindowScreenCurrentState = self.state;
    IMP system = method_getImplementation(class_getInstanceMethod(UIWindowScene.class, @selector(interfaceOrientation)));
    XCTAssertTrue(CGRectEqualToRect(LCWindowScreenAuxiliaryFrame(systemWindow, physical, (const void *)system), physical));
    XCTAssertNil(objc_getAssociatedObject(systemWindow, &LCWindowScreenAdjustedWindowKey));
    UIWindow *detached = [[UIWindow alloc] initWithFrame:physical];
    [self.windows addObject:detached];
    XCTAssertTrue(CGRectEqualToRect(LCWindowScreenAuxiliaryFrame(detached, physical, __builtin_return_address(0)), physical));
    XCTAssertTrue(CGRectEqualToRect(LCWindowScreenAuxiliaryFrame(game, physical, __builtin_return_address(0)), physical));
}
- (void)testWebConfigurationPreservesGuestConfigurationAndUserScripts {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    WKUserContentController *controller = [WKUserContentController new];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:@"window.guestMarker=42;window.initialScreenWidth=screen.width"
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [controller addUserScript:script];
    configuration.userContentController = controller;
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.preferences.minimumFontSize = 13;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    WKWebView *ordinary = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 300, 500) configuration:configuration];
    XCTAssertNil(objc_getAssociatedObject(controller, &LCWindowScreenWebScriptKey));
    XCTAssertEqualObjects(controller.userScripts, @[script]);
    XCTAssertEqual(ordinary.configuration.defaultWebpagePreferences.preferredContentMode, WKContentModeRecommended);
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 300, 500) configuration:configuration];
    XCTAssertEqual(web.configuration.userContentController, controller);
    XCTAssertEqual(web.configuration.websiteDataStore, configuration.websiteDataStore);
    XCTAssertEqual(web.configuration.preferences.minimumFontSize, 13);
    XCTAssertTrue(web.configuration.preferences.javaScriptCanOpenWindowsAutomatically);
    XCTAssertEqual(web.configuration.defaultWebpagePreferences.preferredContentMode, WKContentModeMobile);
    WKUserScript *compatibility = objc_getAssociatedObject(controller, &LCWindowScreenWebScriptKey);
    XCTAssertNotNil(compatibility);
    XCTAssertEqualObjects(controller.userScripts, (@[compatibility, script]));
    XCTAssertTrue(LCWindowScreenConfigureWebConfiguration(web.configuration));
    XCTAssertEqual(controller.userScripts.count, 2);
    WKWebViewConfiguration *desktop = [WKWebViewConfiguration new];
    desktop.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;
    XCTAssertTrue(LCWindowScreenConfigureWebConfiguration(desktop));
    XCTAssertEqual(desktop.defaultWebpagePreferences.preferredContentMode, WKContentModeDesktop);
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    self.webLoaded = [self expectationWithDescription:@"existing guest user script runs after geometry setup"];
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width,initial-scale=1'>" baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    XCTestExpectation *evaluated = [self expectationWithDescription:@"guest script preserved with initial screen size"];
    [web evaluateJavaScript:@"({marker:guestMarker,width:initialScreenWidth})" completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual([result[@"marker"] integerValue], 42);
        XCTAssertEqualWithAccuracy([result[@"width"] doubleValue], 300, 1);
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)testWebAdUsingScreenDimensionsFitsGuestAndKeepsCloseButtonReachable {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:game.bounds];
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    self.webLoaded = [self expectationWithDescription:@"screen-sized web ad loaded"];
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}#ad{position:relative;background:#ddd}#close{position:absolute;right:0;top:0;width:44px;height:44px}</style><div id='ad'><button id='close'>X</button></div><script>function layoutAd(){const ad=document.getElementById('ad');ad.style.width=screen.width+'px';ad.style.height=screen.height+'px'}layoutAd();addEventListener('resize',layoutAd)</script>" baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    XCTestExpectation *evaluated = [self expectationWithDescription:@"web ad respects local screen dimensions"];
    [web evaluateJavaScript:@"({width:innerWidth,height:innerHeight,screenWidth:screen.width,screenHeight:screen.height,adWidth:document.getElementById('ad').getBoundingClientRect().width,adHeight:document.getElementById('ad').getBoundingClientRect().height,closeRight:document.getElementById('close').getBoundingClientRect().right,closeHit:document.elementFromPoint(278,22)===document.getElementById('close')})"
        completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualWithAccuracy([result[@"screenWidth"] doubleValue], 300, 1);
        XCTAssertEqualWithAccuracy([result[@"screenHeight"] doubleValue], 500, 1);
        XCTAssertEqualWithAccuracy([result[@"adWidth"] doubleValue], 300, 1);
        XCTAssertEqualWithAccuracy([result[@"adHeight"] doubleValue], 500, 1);
        XCTAssertLessThanOrEqual([result[@"closeRight"] doubleValue], 300);
        XCTAssertTrue([result[@"closeHit"] boolValue]);
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)testScreenSizedWebAdUpdatesAfterViewportResize {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:game.bounds];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    self.webLoaded = [self expectationWithDescription:@"resizable screen-sized web ad loaded"];
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}#ad{position:relative}#close{position:absolute;right:0;top:0;width:44px;height:44px}</style><div id='ad'><button id='close'>X</button></div><script>function layoutAd(){const ad=document.getElementById('ad');ad.style.width=screen.width+'px';ad.style.height=screen.height+'px'}layoutAd();addEventListener('resize',layoutAd)</script>" baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    game.frame = CGRectMake(0, 0, 600, 400);
    [game layoutIfNeeded];
    XCTestExpectation *evaluated = [self expectationWithDescription:@"resized web ad follows local viewport"];
    // Wait for the web process's actual resize event, bounded by a failure result.
    [web callAsyncJavaScript:@"return await new Promise(resolve=>{const start=performance.now();function check(){if((innerWidth===600&&innerHeight===400&&screen.width===600&&screen.height===400&&document.getElementById('ad').getBoundingClientRect().width===600)||performance.now()-start>5000){resolve({width:innerWidth,height:innerHeight,screenWidth:screen.width,screenHeight:screen.height,adWidth:document.getElementById('ad').getBoundingClientRect().width,adHeight:document.getElementById('ad').getBoundingClientRect().height,closeHit:document.elementFromPoint(578,22)===document.getElementById('close')})}else{requestAnimationFrame(check)}}requestAnimationFrame(check)})"
        arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualWithAccuracy([result[@"width"] doubleValue], 600, 1);
        XCTAssertEqualWithAccuracy([result[@"height"] doubleValue], 400, 1);
        XCTAssertEqualWithAccuracy([result[@"screenWidth"] doubleValue], 600, 1);
        XCTAssertEqualWithAccuracy([result[@"screenHeight"] doubleValue], 400, 1);
        XCTAssertEqualWithAccuracy([result[@"adWidth"] doubleValue], 600, 1);
        XCTAssertEqualWithAccuracy([result[@"adHeight"] doubleValue], 400, 1);
        XCTAssertTrue([result[@"closeHit"] boolValue]);
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)testWebAdRelayoutWhenVisualViewportUpdatesAfterWindowResize {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:game.bounds];
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    self.webLoaded = [self expectationWithDescription:@"deterministic visual viewport ad loaded"];
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width,initial-scale=1'><div id='ad'></div>" baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    WKUserScript *production = web.configuration.userContentController.userScripts.firstObject;
    XCTAssertNotNil(production);
    XCTestExpectation *evaluated = [self expectationWithDescription:@"late viewport update sends bounded main-page relayout"];
    // Execute the production script against controlled DOM event targets in
    // the real web process. No test callback manually lays out the ad after the
    // viewport event: the compatibility script must deliver the window resize.
    [web callAsyncJavaScript:@"const events=new EventTarget(),v=Object.assign(new EventTarget(),{width:300,height:500,scale:1});const FakeScreen=function(){};const localScreen=new FakeScreen(),fake={visualViewport:v,frames:[]};fake.top=fake;fake.parent=fake;new Function('window','Screen','screen','visualViewport','frames','parent','addEventListener','dispatchEvent',script)(fake,FakeScreen,localScreen,v,fake.frames,fake,events.addEventListener.bind(events),events.dispatchEvent.bind(events));let layouts=0,w=0,h=0;function layout(){layouts++;w=localScreen.width;h=localScreen.height}events.addEventListener('resize',layout);layout();events.dispatchEvent(new Event('resize'));v.width=600;v.height=400;v.dispatchEvent(new Event('resize'));const resized={w,h,layouts};v.dispatchEvent(new Event('resize'));return {resized,afterDuplicate:layouts}"
        arguments:@{@"script": production.source} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(result[@"resized"][@"w"], @600);
        XCTAssertEqualObjects(result[@"resized"][@"h"], @400);
        XCTAssertEqualObjects(result[@"resized"][@"layouts"], @3);
        XCTAssertEqualObjects(result[@"afterDuplicate"], @3);
        [evaluated fulfill];
    }];
    [self waitForExpectations:@[evaluated] timeout:10];
}
- (void)testCrossOriginWebAdFrameKeepsGameScreenDimensionsAfterResize {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    WKWebView *web = [[WKWebView alloc] initWithFrame:game.bounds];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    web.navigationDelegate = self;
    [game.rootViewController.view addSubview:web];
    NSString *child = @"<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}#ad{position:relative}#close{position:absolute;right:0;top:0;width:44px;height:44px}</style><div id='ad'><button id='close'>X</button></div><script>function layoutAd(){const ad=document.getElementById('ad');ad.style.width=screen.width+'px';ad.style.height=screen.height+'px';parent.postMessage({type:'adResult',width:screen.width,height:screen.height,adWidth:ad.offsetWidth},'*')}addEventListener('resize',layoutAd);layoutAd()</script>";
    NSString *dataURL = [@"data:text/html;base64," stringByAppendingString:
        [[child dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
    NSString *html = [NSString stringWithFormat:@"<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}iframe{border:0;width:100vw;height:100vh}</style><script>window.adResult=null;addEventListener('message',e=>{if(e.source===document.getElementById('frame').contentWindow&&e.data.type==='adResult')adResult=e.data})</script><iframe id='frame' src='%@'></iframe>", dataURL];
    self.webLoaded = [self expectationWithDescription:@"cross-origin web ad frame loaded"];
    [web loadHTMLString:html baseURL:nil];
    [self waitForExpectations:@[self.webLoaded] timeout:15];
    for (NSNumber *width in @[@300, @600]) {
        CGFloat height = width.doubleValue == 300 ? 500 : 400;
        game.frame = CGRectMake(0, 0, width.doubleValue, height);
        [game layoutIfNeeded];
        XCTestExpectation *evaluated = [self expectationWithDescription:@"cross-origin ad reports the game screen"];
        [web callAsyncJavaScript:@"return await new Promise(resolve=>{const start=performance.now();function check(){if((adResult&&adResult.width===expectedWidth&&adResult.height===expectedHeight&&adResult.adWidth===expectedWidth)||performance.now()-start>5000){resolve(adResult)}else{requestAnimationFrame(check)}}requestAnimationFrame(check)})"
            arguments:@{@"expectedWidth": width, @"expectedHeight": @(height)} inFrame:nil inContentWorld:WKContentWorld.pageWorld
            completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertNotNil(result);
            XCTAssertEqualWithAccuracy([result[@"width"] doubleValue], width.doubleValue, 1);
            XCTAssertEqualWithAccuracy([result[@"height"] doubleValue], height, 1);
            XCTAssertEqualWithAccuracy([result[@"adWidth"] doubleValue], width.doubleValue, 1);
            [evaluated fulfill];
        }];
        [self waitForExpectations:@[evaluated] timeout:10];
    }
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self.webLoaded fulfill]; }
- (void)testGeometryDiagnosticsKeepTheBoundGameAfterAnAdBecomesKey {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    ad.rootViewController = [UIViewController new];
    ad.frame = game.frame;
    [self.windows addObject:ad];
    [ad makeKeyAndVisible];
    NSDictionary *report = LCWindowGeometryDiagnostics();
    XCTAssertEqual(LCWindowScreenGameWindowForDiagnostics(), game);
    XCTAssertTrue([report[@"gameSelected"] boolValue]);
    XCTAssertEqualObjects(report[@"game"][@"bounds"], (@[@0, @0, @300, @500]));
    XCTAssertTrue([report[@"screenCompatibility"][@"enabled"] boolValue]);
    XCTAssertEqualObjects(report[@"screenCompatibility"][@"publishedWidth"], @300);
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:report]);
}
- (void)testGeometryDiagnosticsDistinguishResizedWindowFromCachedMetalDrawable {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    CAMetalLayer *metal = [CAMetalLayer layer];
    metal.bounds = CGRectMake(0, 0, 300, 500);
    metal.contentsScale = 2;
    metal.drawableSize = CGSizeMake(600, 1000);
    [game.layer addSublayer:metal];
    game.frame = CGRectMake(0, 0, 500, 350);
    CGRect before = metal.bounds;
    CGSize drawable = metal.drawableSize;
    NSDictionary *report = LCWindowGeometryDiagnostics();
    XCTAssertEqualObjects(report[@"game"][@"bounds"], (@[@0, @0, @500, @350]));
    XCTAssertEqualObjects(report[@"screenCompatibility"][@"publishedWidth"], @500);
    NSArray *layers = report[@"game"][@"renderLayers"];
    XCTAssertEqual(layers.count, 1U);
    XCTAssertEqualObjects(layers[0][@"bounds"], (@[@0, @0, @300, @500]));
    XCTAssertEqualObjects(layers[0][@"drawableSize"], (@[@600, @1000]));
    XCTAssertTrue(CGRectEqualToRect(metal.bounds, before));
    XCTAssertTrue(CGSizeEqualToSize(metal.drawableSize, drawable));
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:report]);
}
- (void)testTransitionCallbackSeesDestinationScreenBeforeWindowResize {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(297, 834)];
    LCWindowScreenTransitionController *controller = [LCWindowScreenTransitionController new];
    game.rootViewController = controller;
    [game layoutIfNeeded];
    CGRect originalSystemBounds = [UIScreen.mainScreen lc_windowScreen_bounds];
    // Only identity is checked here; the production wrapper must forward the
    // same coordinator, never invent one or invoke a second transition.
    LCWindowScreenTestCoordinator *coordinator = [LCWindowScreenTestCoordinator new];
    coordinator.containerView = game;
    controller.skipsSuper = YES; // An app override may not forward to UIKit.
    for (NSValue *value in @[[NSValue valueWithCGSize:CGSizeMake(416, 596)],
                             [NSValue valueWithCGSize:CGSizeMake(297, 834)]]) {
        CGSize destination = value.CGSizeValue;
        CGSize actual = game.bounds.size;
        NSUInteger calls = controller.calls;
        // UIKit may update the root before the window in another transition
        // path. Both old-root and destination-root callbacks remain eligible.
        if (destination.width == 297) controller.view.bounds = (CGRect){CGPointZero, destination};
        [controller viewWillTransitionToSize:destination withTransitionCoordinator:coordinator];
        XCTAssertEqual(controller.calls, calls + 1);
        XCTAssertEqual(controller.receivedCoordinator, coordinator);
        XCTAssertTrue(CGSizeEqualToSize(controller.receivedSize, destination));
        XCTAssertTrue(CGSizeEqualToSize(controller.actualWindowSizeDuringTransition, actual));
        XCTAssertTrue(CGSizeEqualToSize(controller.screenBeforeSuper.size, destination));
        XCTAssertTrue(CGSizeEqualToSize(controller.screenAfterSuper.size, destination));
        XCTAssertTrue(CGSizeEqualToSize(controller.orientedDuringTransition.size, destination));
        XCTAssertTrue(CGSizeEqualToSize(controller.fixedDuringTransition.size, destination));
        XCTAssertTrue(CGSizeEqualToSize(controller.applicationDuringTransition.size, destination));
        XCTAssertEqualWithAccuracy(controller.nativeDuringTransition.size.width, round(destination.width * UIScreen.mainScreen.nativeScale), 0.01);
        XCTAssertEqualWithAccuracy(controller.nativeDuringTransition.size.height, round(destination.height * UIScreen.mainScreen.nativeScale), 0.01);
        XCTAssertTrue(CGRectEqualToRect(controller.originalSystemBounds, originalSystemBounds));
        XCTAssertTrue(CGSizeEqualToSize(controller.backgroundDuringTransition.size, actual));
        // The scoped callback must leave window/layer sizing to UIKit.
        XCTAssertTrue(CGSizeEqualToSize(game.bounds.size, actual));
        XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, actual));
        game.frame = (CGRect){CGPointZero, destination};
        [game layoutIfNeeded];
        XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, destination));
    }
    NSDictionary *diagnostics = LCWindowScreenGeometryForDiagnostics();
    XCTAssertEqual([diagnostics[@"sizeTransitionCount"] unsignedIntegerValue], 2U);
    XCTAssertEqualObjects(diagnostics[@"lastSizeTransition"][@"targetSize"], (@[@297, @834]));
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:diagnostics]);
}
- (void)testTransitionDestinationIsScopedToTheBoundRootAndMainThread {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    LCWindowScreenInheritedTransitionController *controller = [LCWindowScreenInheritedTransitionController new];
    game.rootViewController = controller;
    [game layoutIfNeeded];
    LCWindowScreenTestCoordinator *coordinator = [LCWindowScreenTestCoordinator new];
    coordinator.containerView = game;
    // Inherited hooks must call the app implementation once, even if its base
    // class was previously wrapped. Nested callbacks cannot replace the root.
    LCWindowScreenTransitionController *child = [LCWindowScreenTransitionController new];
    [controller addChildViewController:child];
    child.view.frame = CGRectMake(0, 0, 100, 120);
    [controller.view addSubview:child.view];
    [child didMoveToParentViewController:controller];
    controller.duringTransition = ^{ [child viewWillTransitionToSize:CGSizeMake(120, 100) withTransitionCoordinator:coordinator]; };
    NSUInteger calls = controller.calls;
    [controller viewWillTransitionToSize:CGSizeMake(600, 400) withTransitionCoordinator:coordinator];
    XCTAssertEqual(controller.calls, calls + 1);
    XCTAssertTrue(CGSizeEqualToSize(controller.screenBeforeSuper.size, CGSizeMake(600, 400)));
    XCTAssertTrue(CGSizeEqualToSize(controller.screenAfterSuper.size, CGSizeMake(600, 400)));
    XCTAssertTrue(CGSizeEqualToSize(child.screenBeforeSuper.size, CGSizeMake(600, 400)));
    XCTAssertTrue(CGSizeEqualToSize(controller.backgroundDuringTransition.size, CGSizeMake(300, 500)));
    XCTAssertEqualWithAccuracy(controller.nativeDuringTransition.size.width, round(400 * UIScreen.mainScreen.nativeScale), 0.01);
    XCTAssertEqualWithAccuracy(controller.nativeDuringTransition.size.height, round(600 * UIScreen.mainScreen.nativeScale), 0.01);
    XCTAssertTrue(CGSizeEqualToSize(controller.fixedDuringTransition.size, CGSizeMake(400, 600)));
    XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, CGSizeMake(300, 500)));
    controller.duringTransition = nil;
    [child viewWillTransitionToSize:CGSizeMake(120, 100) withTransitionCoordinator:coordinator];
    XCTAssertTrue(CGSizeEqualToSize(child.screenBeforeSuper.size, CGSizeMake(300, 500)));
    UIWindow *ad = [[UIWindow alloc] initWithWindowScene:game.windowScene];
    LCWindowScreenTransitionController *adController = [LCWindowScreenTransitionController new];
    ad.rootViewController = adController;
    ad.frame = game.frame;
    [ad makeKeyAndVisible];
    [ad layoutIfNeeded];
    [self.windows addObject:ad];
    [adController viewWillTransitionToSize:CGSizeMake(200, 200) withTransitionCoordinator:coordinator];
    XCTAssertTrue(CGSizeEqualToSize(adController.screenBeforeSuper.size, CGSizeMake(300, 500)));
    XCTAssertEqual(LCWindowScreenGameWindowForDiagnostics(), game);
    XCTAssertEqual([LCWindowScreenGeometryForDiagnostics()[@"sizeTransitionCount"] unsignedIntegerValue], 1U);
}
- (void)testTransitionScopeRestoresAfterExceptionAndWhenDisabled {
    UIWindow *game = [self gameWindowWithSize:CGSizeMake(300, 500)];
    LCWindowScreenTransitionController *controller = [LCWindowScreenTransitionController new];
    game.rootViewController = controller;
    [game layoutIfNeeded];
    LCWindowScreenTestCoordinator *coordinator = [LCWindowScreenTestCoordinator new];
    coordinator.containerView = game;
    controller.throwsOnTransition = YES;
    XCTAssertThrowsSpecificNamed([controller viewWillTransitionToSize:CGSizeMake(500, 350) withTransitionCoordinator:coordinator],
                                 NSException, @"LCWindowScreenTestException");
    XCTAssertTrue(CGSizeEqualToSize(controller.screenBeforeSuper.size, CGSizeMake(500, 350)));
    XCTAssertTrue(CGSizeEqualToSize(UIScreen.mainScreen.bounds.size, CGSizeMake(300, 500)));
    XCTAssertEqual(LCWindowScreenTransitionDepth, 0U);
    controller.throwsOnTransition = NO;
    LCWindowScreenCurrentState = nil;
    CGRect original = UIScreen.mainScreen.bounds;
    NSUInteger calls = controller.calls;
    [controller viewWillTransitionToSize:CGSizeMake(600, 400) withTransitionCoordinator:coordinator];
    XCTAssertEqual(controller.calls, calls + 1);
    XCTAssertTrue(CGRectEqualToRect(controller.screenBeforeSuper, original));
    XCTAssertTrue(CGRectEqualToRect(controller.screenAfterSuper, original));
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, original));
    [self useState:self.state];
    NSUInteger transitions = self.state.sizeTransitionCount;
    controller.skipsSuper = YES; // Do not ask UIKit to perform a NaN transition.
    [controller viewWillTransitionToSize:CGSizeMake(NAN, 400) withTransitionCoordinator:coordinator];
    XCTAssertTrue(CGSizeEqualToSize(controller.screenBeforeSuper.size, CGSizeMake(300, 500)));
    XCTAssertEqual(self.state.sizeTransitionCount, transitions);
}
- (void)testGeometryDiagnosticsBoundWorkAndPreserveDisabledScreenHooks {
    LCWindowScreenCurrentState = nil;
    UIWindow *game = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    for (NSUInteger index = 0; index < 40; index++) [game.layer addSublayer:[CAMetalLayer layer]];
    CGRect screen = UIScreen.mainScreen.bounds;
    NSDictionary *description = LCWindowGeometryDescribeWindow(game);
    XCTAssertEqual([description[@"renderLayers"] count], 32U);
    XCTAssertTrue([description[@"renderTraversalTruncated"] boolValue]);
    XCTAssertEqualObjects(description[@"rootBounds"], @[]);
    XCTAssertNil(LCWindowScreenGameWindowForDiagnostics());
    XCTAssertFalse([LCWindowScreenGeometryForDiagnostics()[@"enabled"] boolValue]);
    XCTAssertTrue(CGRectEqualToRect(UIScreen.mainScreen.bounds, screen));
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:description]);
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    XCTFail(@"Web popup initial load failed: %@", error);
    [self.webLoaded fulfill];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    XCTFail(@"Web popup load failed: %@", error);
    [self.webLoaded fulfill];
}
@end
