#import "WindowScreen.h"
#import <objc/runtime.h>
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

static CGPoint LCWindowScreenFromFixed(CGPoint point, LCWindowScreenSnapshot snapshot) {
    CGSize fixed = LCWindowScreenFixedSize(snapshot);
    switch (snapshot.orientation) {
        case UIInterfaceOrientationLandscapeLeft: return CGPointMake(fixed.height - point.y, point.x);
        case UIInterfaceOrientationLandscapeRight: return CGPointMake(point.y, fixed.width - point.x);
        case UIInterfaceOrientationPortraitUpsideDown: return CGPointMake(fixed.width - point.x, fixed.height - point.y);
        default: return point;
    }
}

static CGPoint LCWindowScreenToFixed(CGPoint point, LCWindowScreenSnapshot snapshot) {
    CGSize fixed = LCWindowScreenFixedSize(snapshot);
    switch (snapshot.orientation) {
        case UIInterfaceOrientationLandscapeLeft: return CGPointMake(point.y, fixed.height - point.x);
        case UIInterfaceOrientationLandscapeRight: return CGPointMake(fixed.width - point.y, point.x);
        case UIInterfaceOrientationPortraitUpsideDown: return CGPointMake(fixed.width - point.x, fixed.height - point.y);
        default: return point;
    }
}

@class LCWindowScreenCoordinateSpace;
@interface LCWindowScreenState : NSObject
@property(nonatomic, weak) UIWindowScene *scene;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) BOOL hasBoundWindow;
@property(nonatomic, strong) NSLock *snapshotLock;
@property(nonatomic) LCWindowScreenSnapshot snapshot;
@property(nonatomic, strong) LCWindowScreenCoordinateSpace *orientedSpace, *fixedSpace;
@property(nonatomic, strong) id<UICoordinateSpace> originalOrientedSpace;
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
        id<UIWindowSceneDelegate> delegate = scene.delegate;
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

static LCWindowScreenState *LCWindowScreenStateForScreen(UIScreen *screen) {
    if (screen != LCWindowScreenMainScreen || LCWindowScreenQueryDepth) return nil;
    LCWindowScreenState *state = LCWindowScreenCurrentState;
    LCWindowScreenRefresh(state);
    return state && LCWindowScreenValidSize(state.readSnapshot.size) ? state : nil;
}

@interface LCWindowScreenCoordinateSpace : NSObject<UICoordinateSpace>
@property(nonatomic, weak) LCWindowScreenState *state;
@property(nonatomic) BOOL fixed;
- (CGRect)convertRect:(CGRect)rect space:(id<UICoordinateSpace>)space from:(BOOL)from;
@end

@implementation LCWindowScreenCoordinateSpace
- (CGRect)bounds {
    LCWindowScreenRefresh(self.state);
    LCWindowScreenSnapshot snapshot = self.state.readSnapshot;
    return (CGRect){CGPointZero, self.fixed ? LCWindowScreenFixedSize(snapshot) : snapshot.size};
}
- (CGPoint)convertPoint:(CGPoint)point toCoordinateSpace:(id<UICoordinateSpace>)space {
    if (space == self) return point;
    LCWindowScreenRefresh(self.state);
    LCWindowScreenSnapshot snapshot = self.state.readSnapshot;
    CGPoint oriented = self.fixed ? LCWindowScreenFromFixed(point, snapshot) : point;
    if (space == LCWindowScreenMainScreen) return oriented;
    if ([(id)space isKindOfClass:LCWindowScreenCoordinateSpace.class] && ((LCWindowScreenCoordinateSpace *)space).state == self.state) {
        return ((LCWindowScreenCoordinateSpace *)space).fixed ? LCWindowScreenToFixed(oriented, snapshot) : oriented;
    }
    LCWindowScreenQueryDepth++;
    UIWindow *window = NSThread.isMainThread ? self.state.window : nil;
    id<UICoordinateSpace> anchor = window ?: self.state.originalOrientedSpace;
    CGRect anchorBounds = window ? window.bounds : CGRectZero;
    CGPoint result = [anchor convertPoint:CGPointMake(oriented.x + anchorBounds.origin.x,
                                                    oriented.y + anchorBounds.origin.y) toCoordinateSpace:space];
    LCWindowScreenQueryDepth--;
    return result;
}
- (CGPoint)convertPoint:(CGPoint)point fromCoordinateSpace:(id<UICoordinateSpace>)space {
    if (space == self) return point;
    LCWindowScreenRefresh(self.state);
    LCWindowScreenSnapshot snapshot = self.state.readSnapshot;
    CGPoint oriented;
    if (space == LCWindowScreenMainScreen) oriented = point;
    else if ([(id)space isKindOfClass:LCWindowScreenCoordinateSpace.class] && ((LCWindowScreenCoordinateSpace *)space).state == self.state) {
        oriented = ((LCWindowScreenCoordinateSpace *)space).fixed ? LCWindowScreenFromFixed(point, snapshot) : point;
    } else {
        LCWindowScreenQueryDepth++;
        UIWindow *window = NSThread.isMainThread ? self.state.window : nil;
        id<UICoordinateSpace> anchor = window ?: self.state.originalOrientedSpace;
        oriented = [anchor convertPoint:point fromCoordinateSpace:space];
        if (window) {
            oriented.x -= window.bounds.origin.x;
            oriented.y -= window.bounds.origin.y;
        }
        LCWindowScreenQueryDepth--;
    }
    return self.fixed ? LCWindowScreenToFixed(oriented, snapshot) : oriented;
}
- (CGRect)convertRect:(CGRect)rect toCoordinateSpace:(id<UICoordinateSpace>)space {
    return [self convertRect:rect space:space from:NO];
}
- (CGRect)convertRect:(CGRect)rect fromCoordinateSpace:(id<UICoordinateSpace>)space {
    return [self convertRect:rect space:space from:YES];
}
- (CGRect)convertRect:(CGRect)rect space:(id<UICoordinateSpace>)space from:(BOOL)from {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) return rect;
    CGPoint corners[] = {{CGRectGetMinX(rect), CGRectGetMinY(rect)}, {CGRectGetMaxX(rect), CGRectGetMinY(rect)},
                         {CGRectGetMinX(rect), CGRectGetMaxY(rect)}, {CGRectGetMaxX(rect), CGRectGetMaxY(rect)}};
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (NSUInteger i = 0; i < 4; i++) {
        CGPoint point = from ? [self convertPoint:corners[i] fromCoordinateSpace:space] :
                              [self convertPoint:corners[i] toCoordinateSpace:space];
        minX = MIN(minX, point.x); minY = MIN(minY, point.y);
        maxX = MAX(maxX, point.x); maxY = MAX(maxY, point.y);
    }
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}
@end

@implementation UIScreen (LCWindowScreen)
- (CGRect)lc_windowScreen_bounds {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? (CGRect){CGPointZero, state.readSnapshot.size} : [self lc_windowScreen_bounds];
}
- (CGRect)lc_windowScreen_nativeBounds {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    if (!state) return [self lc_windowScreen_nativeBounds];
    CGSize size = LCWindowScreenFixedSize(state.readSnapshot);
    return CGRectMake(0, 0, round(size.width * self.nativeScale), round(size.height * self.nativeScale));
}
- (CGRect)lc_windowScreen_applicationFrame {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? (CGRect){CGPointZero, state.readSnapshot.size} : [self lc_windowScreen_applicationFrame];
}
- (id<UICoordinateSpace>)lc_windowScreen_coordinateSpace {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? state.orientedSpace : [self lc_windowScreen_coordinateSpace];
}
- (id<UICoordinateSpace>)lc_windowScreen_fixedCoordinateSpace {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? state.fixedSpace : [self lc_windowScreen_fixedCoordinateSpace];
}
- (CGPoint)lc_windowScreen_convertPoint:(CGPoint)point toCoordinateSpace:(id<UICoordinateSpace>)space {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? [state.orientedSpace convertPoint:point toCoordinateSpace:space] :
                  [self lc_windowScreen_convertPoint:point toCoordinateSpace:space];
}
- (CGPoint)lc_windowScreen_convertPoint:(CGPoint)point fromCoordinateSpace:(id<UICoordinateSpace>)space {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? [state.orientedSpace convertPoint:point fromCoordinateSpace:space] :
                  [self lc_windowScreen_convertPoint:point fromCoordinateSpace:space];
}
- (CGRect)lc_windowScreen_convertRect:(CGRect)rect toCoordinateSpace:(id<UICoordinateSpace>)space {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? [state.orientedSpace convertRect:rect toCoordinateSpace:space] :
                  [self lc_windowScreen_convertRect:rect toCoordinateSpace:space];
}
- (CGRect)lc_windowScreen_convertRect:(CGRect)rect fromCoordinateSpace:(id<UICoordinateSpace>)space {
    LCWindowScreenState *state = LCWindowScreenStateForScreen(self);
    return state ? [state.orientedSpace convertRect:rect fromCoordinateSpace:space] :
                  [self lc_windowScreen_convertRect:rect fromCoordinateSpace:space];
}
@end

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
        state.orientedSpace = [LCWindowScreenCoordinateSpace new];
        state.orientedSpace.state = state;
        state.fixedSpace = [LCWindowScreenCoordinateSpace new];
        state.fixedSpace.state = state;
        state.fixedSpace.fixed = YES;
        LCWindowScreenCurrentState = state;
        LCWindowScreenSwizzle(UIScreen.class, @selector(bounds), @selector(lc_windowScreen_bounds));
        LCWindowScreenSwizzle(UIScreen.class, @selector(nativeBounds), @selector(lc_windowScreen_nativeBounds));
        LCWindowScreenSwizzle(UIScreen.class, @selector(applicationFrame), @selector(lc_windowScreen_applicationFrame));
        LCWindowScreenSwizzle(UIScreen.class, @selector(coordinateSpace), @selector(lc_windowScreen_coordinateSpace));
        LCWindowScreenSwizzle(UIScreen.class, @selector(fixedCoordinateSpace), @selector(lc_windowScreen_fixedCoordinateSpace));
        LCWindowScreenSwizzle(UIScreen.class, @selector(convertPoint:toCoordinateSpace:), @selector(lc_windowScreen_convertPoint:toCoordinateSpace:));
        LCWindowScreenSwizzle(UIScreen.class, @selector(convertPoint:fromCoordinateSpace:), @selector(lc_windowScreen_convertPoint:fromCoordinateSpace:));
        LCWindowScreenSwizzle(UIScreen.class, @selector(convertRect:toCoordinateSpace:), @selector(lc_windowScreen_convertRect:toCoordinateSpace:));
        LCWindowScreenSwizzle(UIScreen.class, @selector(convertRect:fromCoordinateSpace:), @selector(lc_windowScreen_convertRect:fromCoordinateSpace:));
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
