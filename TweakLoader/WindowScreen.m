#import "WindowScreen.h"
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>
#include <math.h>

typedef struct {
    CGSize size;
    UIInterfaceOrientation orientation;
} LCWindowScreenSnapshot;

static BOOL LCWindowScreenValidSize(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width >= 1 && size.height >= 1;
}

// This describes the local screen's fixed coordinate space, not UIKit's scene
// orientation. A portrait-shaped tile can belong to a landscape iPad scene.
static UIInterfaceOrientation LCWindowScreenLocalOrientation(CGSize size, UIInterfaceOrientation sceneOrientation) {
    if (size.width == size.height && sceneOrientation != UIInterfaceOrientationUnknown) return sceneOrientation;
    if (size.height >= size.width) {
        return sceneOrientation == UIInterfaceOrientationPortraitUpsideDown ? sceneOrientation : UIInterfaceOrientationPortrait;
    }
    return UIInterfaceOrientationIsLandscape(sceneOrientation) ? sceneOrientation : UIInterfaceOrientationLandscapeRight;
}

static CGSize LCWindowScreenFixedSize(LCWindowScreenSnapshot snapshot) {
    return UIInterfaceOrientationIsLandscape(snapshot.orientation) ?
        CGSizeMake(snapshot.size.height, snapshot.size.width) : snapshot.size;
}

@interface LCWindowScreenState : NSObject
@property(nonatomic, weak) UIWindowScene *scene;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) BOOL hasBoundWindow;
@property(nonatomic, strong) NSLock *snapshotLock;
@property(nonatomic, strong) NSHashTable<UIWindow *> *adjustedWindows;
@property(nonatomic) LCWindowScreenSnapshot snapshot;
@property(nonatomic, strong) id<UICoordinateSpace> originalOrientedSpace, originalFixedSpace;
- (instancetype)initWithSize:(CGSize)size;
- (LCWindowScreenSnapshot)readSnapshot;
- (void)refreshFromScenes:(NSSet<UIScene *> *)scenes;
@end

static UIScreen *LCWindowScreenMainScreen;
static LCWindowScreenState *LCWindowScreenCurrentState;
static __thread NSUInteger LCWindowScreenQueryDepth;
static const char LCWindowScreenAdjustedWindowKey;
static const char LCWindowScreenWebPreferencesKey;

@interface UIScreen (LCWindowScreenOriginal)
- (CGRect)lc_windowScreen_bounds;
@end

@interface UIWindow (LCWindowScreenInitializers)
- (instancetype)lc_windowScreen_initWithWindowScene:(UIWindowScene *)scene __attribute__((objc_method_family(init)));
- (void)lc_windowScreen_setFrame:(CGRect)frame;
@end

@interface WKWebView (LCWindowScreenInitializers)
- (instancetype)lc_windowScreen_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration __attribute__((objc_method_family(init)));
- (instancetype)lc_windowScreen_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
@end

static BOOL LCWindowScreenIsGameWindow(UIWindow *window, UIWindowScene *scene) {
    return window && window.windowScene == scene && window.windowLevel == UIWindowLevelNormal &&
        window.rootViewController && LCWindowScreenValidSize(window.bounds.size);
}

@implementation LCWindowScreenState
- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super init])) {
        _snapshotLock = [NSLock new];
        _adjustedWindows = [NSHashTable weakObjectsHashTable];
        if (LCWindowScreenValidSize(size)) {
            _snapshot = (LCWindowScreenSnapshot){size, LCWindowScreenLocalOrientation(size, UIInterfaceOrientationUnknown)};
        }
    }
    return self;
}
- (LCWindowScreenSnapshot)readSnapshot {
    [self.snapshotLock lock];
    LCWindowScreenSnapshot snapshot = _snapshot;
    [self.snapshotLock unlock];
    return snapshot;
}
- (void)refreshFromScenes:(NSSet<UIScene *> *)scenes {
    NSAssert(NSThread.isMainThread, @"Window screen geometry is read on the main thread");
    if (self.scene && (![scenes containsObject:self.scene] || self.scene.screen != LCWindowScreenMainScreen)) {
        self.scene = nil;
        self.window = nil;
        self.hasBoundWindow = NO;
    }
    if (!self.scene) {
        UIWindowScene *candidate = nil;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication] ||
                ((UIWindowScene *)scene).screen != LCWindowScreenMainScreen ||
                !LCWindowScreenValidSize(((UIWindowScene *)scene).coordinateSpace.bounds.size)) continue;
            // Multiple application scenes have no unambiguous process-wide size.
            if (candidate) return;
            candidate = (UIWindowScene *)scene;
        }
        self.scene = candidate;
    }
    UIWindowScene *scene = self.scene;
    if (!scene) return; // Keep the startup/last valid snapshot during disconnection.
    if (!LCWindowScreenIsGameWindow(self.window, scene)) {
        self.window = nil;
        id<UIWindowSceneDelegate> delegate = (id)scene.delegate;
        UIWindow *delegateWindow = [delegate respondsToSelector:@selector(window)] ? delegate.window : nil;
        if (LCWindowScreenIsGameWindow(delegateWindow, scene) &&
            (!self.hasBoundWindow || CGSizeEqualToSize(delegateWindow.bounds.size, scene.coordinateSpace.bounds.size))) {
            self.window = delegateWindow;
        }
        if (!self.window) {
            for (UIWindow *window in scene.windows) {
                if (!LCWindowScreenIsGameWindow(window, scene) || window.hidden) continue;
                // Once the game window has gone away, do not adopt an oversized
                // replacement ad. Its scene remains a stable geometry fallback.
                if (self.hasBoundWindow && !CGSizeEqualToSize(window.bounds.size, scene.coordinateSpace.bounds.size)) continue;
                self.window = window;
                break;
            }
        }
    }
    CGSize size;
    if (self.window) {
        self.hasBoundWindow = YES;
        size = self.window.bounds.size;
    } else if (self.hasBoundWindow || !LCWindowScreenValidSize(self.readSnapshot.size)) {
        size = scene.coordinateSpace.bounds.size;
    } else {
        return; // SDK initialization before the game window uses launch geometry.
    }
    if (!LCWindowScreenValidSize(size)) return;
    LCWindowScreenSnapshot snapshot = {size, LCWindowScreenLocalOrientation(size, scene.interfaceOrientation)};
    [self.snapshotLock lock];
    _snapshot = snapshot;
    [self.snapshotLock unlock];
}
@end

static void LCWindowScreenRefresh(LCWindowScreenState *state) {
    if (!state || !NSThread.isMainThread || LCWindowScreenQueryDepth) return;
    LCWindowScreenQueryDepth++;
    [state refreshFromScenes:UIApplication.sharedApplication.connectedScenes];
    LCWindowScreenQueryDepth--;
}

// Keep UIKit's own geometry reads physical. Its private scene converters rely
// on real screen coordinate-space identities and the actual display transform.
// Only direct game/third-party SDK calls receive the compatibility dimensions.
static BOOL LCWindowScreenCallerUsesPhysicalGeometry(const void *caller) {
    Dl_info info;
    if (!caller || dladdr(caller, &info) == 0 || !info.dli_fname) return YES;
    return strstr(info.dli_fname, "/System/Library/") || strstr(info.dli_fname, "/usr/lib/");
}

static LCWindowScreenState *LCWindowScreenStateForScreen(UIScreen *screen, const void *caller) {
    if (screen != LCWindowScreenMainScreen || LCWindowScreenQueryDepth ||
        !LCWindowScreenCurrentState || LCWindowScreenCallerUsesPhysicalGeometry(caller)) return nil;
    LCWindowScreenState *state = LCWindowScreenCurrentState;
    LCWindowScreenRefresh(state);
    return LCWindowScreenValidSize(state.readSnapshot.size) ? state : nil;
}

static BOOL LCWindowScreenSameSize(CGSize a, CGSize b) {
    return fabs(a.width - b.width) < 0.5 && fabs(a.height - b.height) < 0.5;
}

static BOOL LCWindowScreenIsWholeSceneSize(CGSize size, LCWindowScreenState *state) {
    CGSize physical = [LCWindowScreenMainScreen lc_windowScreen_bounds].size;
    CGSize scene = state.scene.coordinateSpace.bounds.size;
    return LCWindowScreenSameSize(size, physical) ||
        LCWindowScreenSameSize(size, CGSizeMake(physical.height, physical.width)) ||
        (LCWindowScreenValidSize(scene) && (LCWindowScreenSameSize(size, scene) ||
         LCWindowScreenSameSize(size, CGSizeMake(scene.height, scene.width))));
}

static LCWindowScreenState *LCWindowScreenStateForAuxiliaryWindow(UIWindow *window, const void *caller) {
    LCWindowScreenState *state = LCWindowScreenCurrentState;
    if (!NSThread.isMainThread || LCWindowScreenQueryDepth || !state || window == state.window ||
        !LCWindowScreenIsGameWindow(state.window, state.scene) || window.windowScene != state.scene ||
        (LCWindowScreenCallerUsesPhysicalGeometry(caller) &&
         !objc_getAssociatedObject(window, &LCWindowScreenAdjustedWindowKey))) return nil;
    return state;
}

static void LCWindowScreenRememberAdjustedWindow(UIWindow *window, LCWindowScreenState *state) {
    objc_setAssociatedObject(window, &LCWindowScreenAdjustedWindowKey,
        [NSValue valueWithCGRect:window.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state.adjustedWindows addObject:window];
}

static void LCWindowScreenForgetAdjustedWindow(UIWindow *window, LCWindowScreenState *state) {
    objc_setAssociatedObject(window, &LCWindowScreenAdjustedWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state.adjustedWindows removeObject:window];
}

// Follow game resize/rotation only while an automatically fitted window retains
// its fitted frame. A later custom popup rectangle relinquishes this behavior.
static void LCWindowScreenRefitAdjustedWindows(LCWindowScreenState *state) {
    if (!NSThread.isMainThread || LCWindowScreenQueryDepth ||
        !LCWindowScreenIsGameWindow(state.window, state.scene)) return;
    CGRect target = state.window.frame;
    if (!LCWindowScreenValidSize(target.size)) return;
    LCWindowScreenQueryDepth++;
    for (UIWindow *window in state.adjustedWindows.allObjects) {
        NSValue *previous = objc_getAssociatedObject(window, &LCWindowScreenAdjustedWindowKey);
        if (!previous || window == state.window || window.windowScene != state.scene ||
            !CGRectEqualToRect(window.frame, previous.CGRectValue)) {
            LCWindowScreenForgetAdjustedWindow(window, state);
        } else if (!CGRectEqualToRect(window.frame, target)) {
            [window lc_windowScreen_setFrame:target];
            LCWindowScreenRememberAdjustedWindow(window, state);
        }
    }
    LCWindowScreenQueryDepth--;
}

static CGRect LCWindowScreenAuxiliaryFrame(UIWindow *window, CGRect frame, const void *caller) {
    LCWindowScreenState *state = LCWindowScreenStateForAuxiliaryWindow(window, caller);
    if (!state) return frame;
    if (!LCWindowScreenIsWholeSceneSize(frame.size, state)) {
        NSValue *previous = objc_getAssociatedObject(window, &LCWindowScreenAdjustedWindowKey);
        if (previous && !CGRectEqualToRect(frame, previous.CGRectValue) &&
            !CGRectEqualToRect(frame, state.window.frame)) LCWindowScreenForgetAdjustedWindow(window, state);
        return frame;
    }
    CGRect target = state.window.frame;
    if (!LCWindowScreenValidSize(target.size) || CGRectEqualToRect(frame, target)) return frame;
    LCWindowScreenRememberAdjustedWindow(window, state);
    return target;
}

// WebKit's screen.* is computed in its web process. This per-preferences engine
// setting reports that page's actual viewport and does not change UIKit geometry
// or inject JavaScript into the advertisement. Resolve SPI at runtime so missing
// functions leave the ordinary WebKit configuration intact.
static BOOL LCWindowScreenConfigureWebPreferences(WKPreferences *preferences) {
    if (!NSThread.isMainThread || !LCWindowScreenCurrentState || !preferences) return NO;
    if (objc_getAssociatedObject(preferences, &LCWindowScreenWebPreferencesKey)) return YES;
    typedef const void *(*CreateString)(const char *);
    typedef void (*SetBool)(const void *, bool, const void *);
    typedef void (*Release)(const void *);
    static CreateString createString;
    static SetBool setBool;
    static Release release;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createString = (CreateString)dlsym(RTLD_DEFAULT, "WKStringCreateWithUTF8CString");
        setBool = (SetBool)dlsym(RTLD_DEFAULT, "WKPreferencesSetBoolValueForKeyForTesting");
        release = (Release)dlsym(RTLD_DEFAULT, "WKRelease");
    });
    if (!createString || !setBool || !release) return NO;
    const void *key = createString("ShouldReportViewportSizeAsScreenSize");
    if (!key) return NO;
    // On Cocoa, WKPreferencesRef is the WKPreferences wrapper, not its C++ ivar.
    setBool((__bridge const void *)preferences, true, key);
    release(key);
    objc_setAssociatedObject(preferences, &LCWindowScreenWebPreferencesKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

@implementation UIScreen (LCWindowScreen)
- (CGRect)lc_windowScreen_bounds {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self, __builtin_return_address(0));
    return state ? (CGRect){CGPointZero, state.readSnapshot.size} : [self lc_windowScreen_bounds];
}
- (CGRect)lc_windowScreen_nativeBounds {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self, __builtin_return_address(0));
    if (!state) return [self lc_windowScreen_nativeBounds];
    CGSize size = LCWindowScreenFixedSize(state.readSnapshot);
    return CGRectMake(0, 0, round(size.width * self.nativeScale), round(size.height * self.nativeScale));
}
- (CGRect)lc_windowScreen_applicationFrame {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self, __builtin_return_address(0));
    return state ? (CGRect){CGPointZero, state.readSnapshot.size} : [self lc_windowScreen_applicationFrame];
}
@end

static CGRect LCWindowScreenCoordinateSpaceBounds(id space, SEL selector) {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(LCWindowScreenMainScreen, __builtin_return_address(0));
    if (state && (space == state.originalOrientedSpace || space == state.originalFixedSpace)) {
        CGSize size = space == state.originalFixedSpace ? LCWindowScreenFixedSize(state.readSnapshot) : state.readSnapshot.size;
        return (CGRect){CGPointZero, size};
    }
    CGRect (*original)(id, SEL) = (void *)objc_msgSend;
    return original(space, NSSelectorFromString(@"lc_windowScreen_spaceBounds"));
}

@implementation UIWindow (LCWindowScreen)
- (instancetype)lc_windowScreen_initWithWindowScene:(UIWindowScene *)scene {
    const void *caller = __builtin_return_address(0);
    UIWindow *window = [self lc_windowScreen_initWithWindowScene:scene];
    if (window) {
        CGRect frame = LCWindowScreenAuxiliaryFrame(window, window.frame, caller);
        if (!CGRectEqualToRect(frame, window.frame)) [window lc_windowScreen_setFrame:frame];
        if (objc_getAssociatedObject(window, &LCWindowScreenAdjustedWindowKey))
            LCWindowScreenRememberAdjustedWindow(window, LCWindowScreenCurrentState);
    }
    return window;
}
- (void)lc_windowScreen_setBounds:(CGRect)bounds {
    LCWindowScreenState *state = LCWindowScreenStateForAuxiliaryWindow(self, __builtin_return_address(0));
    if (state && LCWindowScreenIsWholeSceneSize(bounds.size, state)) {
        bounds.size = state.window.bounds.size;
        LCWindowScreenRememberAdjustedWindow(self, state);
    } else if (state && !LCWindowScreenSameSize(bounds.size, state.window.bounds.size)) {
        LCWindowScreenForgetAdjustedWindow(self, state);
    }
    [self lc_windowScreen_setBounds:bounds];
    if (state && objc_getAssociatedObject(self, &LCWindowScreenAdjustedWindowKey))
        LCWindowScreenRememberAdjustedWindow(self, state);
    if (self == LCWindowScreenCurrentState.window) {
        LCWindowScreenRefresh(LCWindowScreenCurrentState);
        LCWindowScreenRefitAdjustedWindows(LCWindowScreenCurrentState);
    }
}
- (void)lc_windowScreen_setFrame:(CGRect)frame {
    frame = LCWindowScreenAuxiliaryFrame(self, frame, __builtin_return_address(0));
    [self lc_windowScreen_setFrame:frame];
    if (objc_getAssociatedObject(self, &LCWindowScreenAdjustedWindowKey))
        LCWindowScreenRememberAdjustedWindow(self, LCWindowScreenCurrentState);
    if (self == LCWindowScreenCurrentState.window) {
        LCWindowScreenRefresh(LCWindowScreenCurrentState);
        LCWindowScreenRefitAdjustedWindows(LCWindowScreenCurrentState);
    }
}
- (void)lc_windowScreen_makeKeyAndVisible {
    CGRect frame = LCWindowScreenAuxiliaryFrame(self, self.frame, __builtin_return_address(0));
    if (!CGRectEqualToRect(frame, self.frame)) [self lc_windowScreen_setFrame:frame];
    if (objc_getAssociatedObject(self, &LCWindowScreenAdjustedWindowKey))
        LCWindowScreenRememberAdjustedWindow(self, LCWindowScreenCurrentState);
    [self lc_windowScreen_makeKeyAndVisible];
}
@end

@implementation WKWebView (LCWindowScreen)
- (instancetype)lc_windowScreen_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    LCWindowScreenConfigureWebPreferences(configuration.preferences);
    WKWebView *web = [self lc_windowScreen_initWithFrame:frame configuration:configuration];
    LCWindowScreenConfigureWebPreferences(web.configuration.preferences);
    return web;
}
- (instancetype)lc_windowScreen_initWithCoder:(NSCoder *)coder {
    WKWebView *web = [self lc_windowScreen_initWithCoder:coder];
    LCWindowScreenConfigureWebPreferences(web.configuration.preferences);
    return web;
}
- (void)lc_windowScreen_didMoveToWindow {
    [self lc_windowScreen_didMoveToWindow];
    LCWindowScreenConfigureWebPreferences(self.configuration.preferences);
}
@end

static void LCWindowScreenSwizzle(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) return;
    // UIWindow inherits its setters from UIView; keep the replacement local.
    class_addMethod(cls, original, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    method_exchangeImplementations(class_getInstanceMethod(cls, original), replacementMethod);
}

BOOL LCWindowScreenShouldEnable(BOOL isLiveProcess, NSString *guestAppId, NSDictionary *appInfo, NSDictionary *launchInfo) {
    return isLiveProcess && guestAppId.length && [appInfo[@"LCUseWindowScreenSize"] isEqual:@YES] &&
        ![appInfo[@"dontInjectTweakLoader"] boolValue] && [launchInfo[@"virtualWindow"] isEqual:@YES];
}

void LCWindowScreenInstall(NSDictionary *launchInfo) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCWindowScreenMainScreen = UIScreen.mainScreen;
        id width = launchInfo[@"initialWindowWidth"], height = launchInfo[@"initialWindowHeight"];
        CGSize initial = [width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class] ?
            CGSizeMake([width doubleValue], [height doubleValue]) : CGSizeZero;
        LCWindowScreenState *state = [[LCWindowScreenState alloc] initWithSize:initial];
        state.originalOrientedSpace = LCWindowScreenMainScreen.coordinateSpace;
        state.originalFixedSpace = LCWindowScreenMainScreen.fixedCoordinateSpace;
        LCWindowScreenCurrentState = state;
        LCWindowScreenSwizzle(UIScreen.class, @selector(bounds), @selector(lc_windowScreen_bounds));
        LCWindowScreenSwizzle(UIScreen.class, @selector(nativeBounds), @selector(lc_windowScreen_nativeBounds));
        LCWindowScreenSwizzle(UIScreen.class, @selector(applicationFrame), @selector(lc_windowScreen_applicationFrame));
        // Keep the original objects and all converters. Hook only their bounds
        // getter, and only for the two objects belonging to this process's screen.
        NSMutableSet *classes = [NSMutableSet set];
        for (id space in @[state.originalOrientedSpace, state.originalFixedSpace]) {
            Class cls = object_getClass(space);
            if ([space isKindOfClass:UIScreen.class] || [classes containsObject:cls]) continue;
            Method bounds = class_getInstanceMethod(cls, @selector(bounds));
            SEL replacement = NSSelectorFromString(@"lc_windowScreen_spaceBounds");
            if (bounds && class_addMethod(cls, replacement, (IMP)LCWindowScreenCoordinateSpaceBounds, method_getTypeEncoding(bounds))) {
                LCWindowScreenSwizzle(cls, @selector(bounds), replacement);
                [classes addObject:cls];
            }
        }
        LCWindowScreenSwizzle(UIWindow.class, @selector(setBounds:), @selector(lc_windowScreen_setBounds:));
        LCWindowScreenSwizzle(UIWindow.class, @selector(setFrame:), @selector(lc_windowScreen_setFrame:));
        LCWindowScreenSwizzle(UIWindow.class, @selector(initWithWindowScene:), @selector(lc_windowScreen_initWithWindowScene:));
        LCWindowScreenSwizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(lc_windowScreen_makeKeyAndVisible));
        LCWindowScreenSwizzle(WKWebView.class, @selector(initWithFrame:configuration:), @selector(lc_windowScreen_initWithFrame:configuration:));
        LCWindowScreenSwizzle(WKWebView.class, @selector(initWithCoder:), @selector(lc_windowScreen_initWithCoder:));
        LCWindowScreenSwizzle(WKWebView.class, @selector(didMoveToWindow), @selector(lc_windowScreen_didMoveToWindow));
        // A background SDK reads a locked snapshot. Window changes and lifecycle
        // notifications refresh it without a timer or background UIKit access.
        for (NSString *name in @[UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeKeyNotification,
                                 UISceneDidActivateNotification, UISceneDidDisconnectNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                       usingBlock:^(NSNotification *note) {
                LCWindowScreenRefresh(LCWindowScreenCurrentState);
                LCWindowScreenRefitAdjustedWindows(LCWindowScreenCurrentState);
            }];
        }
    });
}
