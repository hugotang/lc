#import <XCTest/XCTest.h>
#import "../TweakLoader/GuestWindows.h"

@interface LCGuestWindowsTestSession : NSObject
@property(nonatomic, copy) UISceneSessionRole role;
@end
@implementation LCGuestWindowsTestSession
@end

@interface LCGuestWindowsTestScene : NSObject
@property(nonatomic, strong) LCGuestWindowsTestSession *session;
@property(nonatomic, strong) UIScreen *screen;
@property(nonatomic) UISceneActivationState activationState;
@property(nonatomic, copy) NSArray<UIWindow *> *windows;
@end
@implementation LCGuestWindowsTestScene
- (BOOL)isKindOfClass:(Class)cls { return cls == UIWindowScene.class || [super isKindOfClass:cls]; }
@end

@interface LCGuestWindowsTestWindow : NSObject
@property(nonatomic, weak) UIWindowScene *windowScene;
@property(nonatomic) UIWindowLevel windowLevel;
@property(nonatomic, strong) UIViewController *rootViewController;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic, getter=isKeyWindow) BOOL keyWindow;
@end
@implementation LCGuestWindowsTestWindow
@end

@interface GuestWindowsTests : XCTestCase
@end
@implementation GuestWindowsTests
- (LCGuestWindowsTestScene *)scene {
    LCGuestWindowsTestScene *scene = [LCGuestWindowsTestScene new];
    scene.session = [LCGuestWindowsTestSession new];
    scene.session.role = UIWindowSceneSessionRoleApplication;
    scene.screen = UIScreen.mainScreen;
    scene.activationState = UISceneActivationStateForegroundActive;
    return scene;
}
- (LCGuestWindowsTestWindow *)window:(LCGuestWindowsTestScene *)scene {
    LCGuestWindowsTestWindow *window = [LCGuestWindowsTestWindow new];
    window.windowScene = (id)scene;
    window.rootViewController = [UIViewController new];
    return window;
}
- (void)testLegacyEmptyListRecoversAcrossForegroundCycle {
    LCGuestWindowsTestScene *scene = self.scene;
    LCGuestWindowsTestWindow *window = [self window:scene];
    scene.windows = @[(id)window];
    for (NSNumber *state in @[@(UISceneActivationStateForegroundActive), @(UISceneActivationStateBackground),
                              @(UISceneActivationStateForegroundInactive), @(UISceneActivationStateForegroundActive)]) {
        scene.activationState = state.integerValue;
        NSArray *result = LCGuestWindowsFallback(@[], (id)[NSSet setWithObject:scene], UIScreen.mainScreen);
        XCTAssertEqual(result.count, 1u);
        XCTAssertEqual(result.firstObject, window);
    }
}
- (void)testExistingResultsRetainOriginalOrderAndIdentity {
    LCGuestWindowsTestScene *scene = self.scene;
    NSArray *original = @[(id)[self window:scene]];
    XCTAssertEqual(LCGuestWindowsFallback(original, (id)[NSSet setWithObject:scene], UIScreen.mainScreen), original);
}
- (void)testExternalDisconnectedAndAmbiguousScenesDoNotBecomeGuestWindows {
    LCGuestWindowsTestScene *first = self.scene, *second = self.scene;
    first.windows = @[(id)[self window:first]];
    second.windows = @[(id)[self window:second]];
    NSSet *scenes = (id)[NSSet setWithObjects:first, second, nil];
    XCTAssertEqual(LCGuestWindowsFallback(@[], scenes, UIScreen.mainScreen).count, 0u);
    second.session.role = UIWindowSceneSessionRoleExternalDisplayNonInteractive;
    XCTAssertEqualObjects(LCGuestWindowsFallback(@[], scenes, UIScreen.mainScreen), first.windows);
    first.activationState = UISceneActivationStateUnattached;
    XCTAssertEqual(LCGuestWindowsFallback(@[], scenes, UIScreen.mainScreen).count, 0u);
}
- (void)testAuxiliaryAndForeignWindowsAreExcludedAndKeyWindowComesFirst {
    LCGuestWindowsTestScene *scene = self.scene, *foreign = self.scene;
    LCGuestWindowsTestWindow *normal = [self window:scene], *key = [self window:scene], *overlay = [self window:scene];
    key.keyWindow = YES;
    overlay.windowLevel = UIWindowLevelAlert;
    scene.windows = @[(id)normal, (id)overlay, (id)[self window:foreign], (id)key, (id)normal];
    XCTAssertEqualObjects(LCGuestWindowsFallback(@[], (id)[NSSet setWithObject:scene], UIScreen.mainScreen), (@[key, normal]));
}
- (void)testActiveSceneWinsOverBackgroundAndBackgroundAmbiguityStaysEmpty {
    LCGuestWindowsTestScene *first = self.scene, *second = self.scene;
    first.windows = @[(id)[self window:first]];
    second.windows = @[(id)[self window:second]];
    second.activationState = UISceneActivationStateBackground;
    NSSet *scenes = (id)[NSSet setWithObjects:first, second, nil];
    XCTAssertEqualObjects(LCGuestWindowsFallback(@[], scenes, UIScreen.mainScreen), first.windows);
    first.activationState = UISceneActivationStateBackground;
    XCTAssertEqual(LCGuestWindowsFallback(@[], scenes, UIScreen.mainScreen).count, 0u);
}
@end
