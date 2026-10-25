#import "WindowScreen.h"
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
@property(nonatomic) LCWindowScreenSnapshot snapshot;
@property(nonatomic, strong) id<UICoordinateSpace> originalOrientedSpace, originalFixedSpace;
- (instancetype)initWithSize:(CGSize)size;
- (LCWindowScreenSnapshot)readSnapshot;
- (void)refreshFromScenes:(NSSet<UIScene *> *)scenes;
@end

static UIScreen *LCWindowScreenMainScreen;
static LCWindowScreenState *LCWindowScreenCurrentState;
static __thread NSUInteger LCWindowScreenQueryDepth;

static BOOL LCWindowScreenIsGameWindow(UIWindow *window, UIWindowScene *scene) {
    return window && window.windowScene == scene && window.windowLevel == UIWindowLevelNormal &&
        window.rootViewController && LCWindowScreenValidSize(window.bounds.size);
}

@implementation LCWindowScreenState
- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super init])) {
        _snapshotLock = [NSLock new];
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
- (void)lc_windowScreen_setBounds:(CGRect)bounds {
    [self lc_windowScreen_setBounds:bounds];
    if (self == LCWindowScreenCurrentState.window) LCWindowScreenRefresh(LCWindowScreenCurrentState);
}
- (void)lc_windowScreen_setFrame:(CGRect)frame {
    [self lc_windowScreen_setFrame:frame];
    if (self == LCWindowScreenCurrentState.window) LCWindowScreenRefresh(LCWindowScreenCurrentState);
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
        // A background SDK reads a locked snapshot. Window changes and lifecycle
        // notifications refresh it without a timer or background UIKit access.
        for (NSString *name in @[UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeKeyNotification,
                                 UISceneDidActivateNotification, UISceneDidDisconnectNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                       usingBlock:^(NSNotification *note) {
                LCWindowScreenRefresh(LCWindowScreenCurrentState);
            }];
        }
    });
}
