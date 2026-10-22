#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "../LiveContainer/utils.h"
#import "../MultitaskSupport/TapSyncProtocol.h"

// These setters are used only inside the selected guest process. No system-wide HID injection is used.
typedef struct __IOHIDEvent *LCTapHIDEventRef;
@interface UITouch (LCTapSyncPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setGestureView:(UIView *)view;
- (void)setTapCount:(NSUInteger)count;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)point resetPrevious:(BOOL)reset;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setIsTapToClick:(BOOL)tap;
- (void)_setHidEvent:(LCTapHIDEventRef)event;
@end
@interface UIApplication (LCTapSyncPrivate)
- (UIEvent *)_touchesEvent;
@end
@interface UIApplication (LCTapSyncHook)
- (void)lc_tapSync_sendEvent:(UIEvent *)event;
@end
@interface UIEvent (LCTapSyncPrivate)
- (instancetype)_init;
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(LCTapHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end
@interface LiveProcessHandler : NSObject
+ (NSDictionary *)retrievedAppInfo;
@end

// ABI declarations follow WebKit's IOKitSPIIOS.h (see docs/TapSync.md).
static LCTapHIDEventRef (*createHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                    double, double, double, double, double, boolean_t, boolean_t, uint32_t);
static LCTapHIDEventRef (*createFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                      double, double, double, double, double, boolean_t, boolean_t, uint32_t);
static void (*appendHID)(LCTapHIDEventRef, LCTapHIDEventRef, uint32_t);
static void (*setHIDInteger)(LCTapHIDEventRef, uint32_t, CFIndex);

static UIEvent *LCTapNewEvent(void) {
    Class eventClass = NSClassFromString(@"UITouchesEvent");
    if (![eventClass isSubclassOfClass:UIEvent.class] || ![eventClass instancesRespondToSelector:@selector(_init)]) return nil;
    return [[eventClass alloc] _init];
}

static BOOL LCTapReplayAvailable(void) {
    static BOOL symbolsAvailable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        if (!library) return;
        createHand = dlsym(library, "IOHIDEventCreateDigitizerEvent");
        createFinger = dlsym(library, "IOHIDEventCreateDigitizerFingerEvent");
        appendHID = dlsym(library, "IOHIDEventAppendEvent");
        setHIDInteger = dlsym(library, "IOHIDEventSetIntegerValue");
        symbolsAvailable = createHand && createFinger && appendHID && setHIDInteger;
    });
    if (!symbolsAvailable || ![UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)]) return NO;
    for (NSString *name in @[@"setWindow:", @"setView:", @"setTapCount:", @"setTimestamp:", @"setPhase:",
                             @"_setLocationInWindow:resetPrevious:", @"_setHidEvent:"]) {
        if (![UITouch instancesRespondToSelector:NSSelectorFromString(name)]) return NO;
    }
    @try {
        UIEvent *event = LCTapNewEvent();
        return [event respondsToSelector:@selector(_clearTouches)] &&
            [event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)] &&
            [event respondsToSelector:@selector(_setHIDEvent:)] && [event respondsToSelector:@selector(_setTimestamp:)];
    } @catch (NSException *exception) { return NO; }
}

static UIWindow *LCTapSyncGuestWindow(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0 && window.userInteractionEnabled &&
                window.windowLevel > UIWindowLevelNormal && window.rootViewController) return nil;
            if (!window.hidden && window.alpha > 0 && window.windowLevel == UIWindowLevelNormal && window.rootViewController) {
                [windows addObject:window];
            }
        }
    }
    UIWindow *keyWindow = nil;
    for (UIWindow *window in windows) {
        if (!window.isKeyWindow) continue;
        if (keyWindow) return nil;
        keyWindow = window;
    }
    return keyWindow ?: (windows.count == 1 ? windows.firstObject : nil);
}

static BOOL LCTapHasRealTouches(UIEvent *event) {
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) return YES;
    }
    return NO;
}

static LCTapHIDEventRef LCTapCreateHID(UITouch *touch) {
    BOOL down = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
    uint32_t mask = 3 | (touch.phase == UITouchPhaseCancelled ? 0x80 : 0); // range, touch, optional cancel
    uint64_t time = mach_absolute_time();
    LCTapHIDEventRef hand = createHand(kCFAllocatorDefault, time, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, down, down, 0);
    if (!hand) return NULL;
    CGPoint point = [touch locationInView:touch.window];
    LCTapHIDEventRef finger = createFinger(kCFAllocatorDefault, time, 1, 2, mask, point.x, point.y, 0, 0, 0, down, down, 0);
    if (!finger) { CFRelease(hand); return NULL; }
    // kIOHIDEventFieldDigitizerIsDisplayIntegrated
    setHIDInteger(hand, (11 << 16) + 25, 1);
    setHIDInteger(finger, (11 << 16) + 25, 1);
    appendHID(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

@interface LCTapSyncClient : NSObject <LCTapSyncGuestProtocol>
@property(nonatomic) NSXPCConnection *connection;
@property(nonatomic, copy) NSString *session;
@property(nonatomic) BOOL source, replaying, supported, keyboardVisible;
@property(nonatomic) uint64_t sequence;
@property(nonatomic, weak) UITouch *candidate;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGRect sourceBounds;
@property(nonatomic) UIInterfaceOrientation sourceOrientation;
@property(nonatomic) UIEdgeInsets sourceInsets;
@property(nonatomic) NSTimeInterval startTime;
@property(nonatomic) double maximumTravel;
@property(nonatomic) UITouch *syntheticTouch;
@property(nonatomic) UIEvent *syntheticEvent;
@property(nonatomic) CGRect replayBounds;
@property(nonatomic) UIEdgeInsets replayInsets;
@property(nonatomic) UIInterfaceOrientation replayOrientation;
@property(nonatomic, copy) void (^replayReply)(LCTapSyncResult);
- (void)observeEvent:(UIEvent *)event;
- (void)interrupt:(LCTapSyncResult)reason;
@end

static LCTapSyncClient *tapSyncClient;

@implementation LCTapSyncClient
- (void)prepareSession:(NSString *)session source:(BOOL)source reply:(void (^)(LCTapSyncResult))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishReplay:LCTapSyncResultStopped];
        self.session = nil;
        self.candidate = nil;
        UIWindow *window = LCTapSyncGuestWindow();
        if (![session isKindOfClass:NSString.class] || session.length != 36 || !window || self.keyboardVisible) {
            reply(LCTapSyncResultUnavailable); return;
        }
        if (window.bounds.size.width < 1 || window.bounds.size.height < 1 || window.windowScene.interfaceOrientation == UIInterfaceOrientationUnknown) {
            reply(LCTapSyncResultUnavailable); return;
        }
        if (!source && !self.supported) { reply(LCTapSyncResultUnsupported); return; }
        @try {
            if ([UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)] &&
                LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent])) {
                reply(LCTapSyncResultBusy); return;
            }
        } @catch (NSException *exception) { reply(LCTapSyncResultUnsupported); return; }
        self.session = session;
        self.source = source;
        self.sequence = 0;
        reply(LCTapSyncResultAccepted);
    });
}
- (void)stopSession:(NSString *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.session isEqualToString:session]) return;
        self.session = nil;
        self.candidate = nil;
        [self finishReplay:LCTapSyncResultStopped];
    });
}
- (void)interrupt:(LCTapSyncResult)reason {
    NSString *session = self.session;
    self.session = nil;
    self.candidate = nil;
    [self finishReplay:reason];
    if (session) {
        id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
        [host interruptSession:session reason:reason];
    }
}
- (void)observeEvent:(UIEvent *)event {
    if (!self.session || self.replaying || event.type != UIEventTypeTouches) return;
    if (!self.source) {
        if (LCTapHasRealTouches(event)) [self interrupt:LCTapSyncResultBusy];
        return;
    }
    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count != 1) { self.candidate = nil; return; }
    UITouch *touch = touches.anyObject;
    UIWindow *window = touch.window;
    if (touch.type != UITouchTypeDirect || !window || window != LCTapSyncGuestWindow() || self.keyboardVisible) {
        self.candidate = nil; return;
    }
    CGPoint point = [touch locationInView:window];
    if (touch.phase == UITouchPhaseBegan) {
        self.candidate = touch;
        self.startPoint = point;
        self.startTime = touch.timestamp;
        self.sourceBounds = window.bounds;
        self.sourceInsets = window.safeAreaInsets;
        self.sourceOrientation = window.windowScene.interfaceOrientation;
        self.maximumTravel = 0;
        return;
    }
    if (self.candidate != touch) return;
    for (UITouch *sample in [event coalescedTouchesForTouch:touch] ?: @[touch]) {
        CGPoint position = [sample locationInView:window];
        self.maximumTravel = MAX(self.maximumTravel, hypot(position.x - self.startPoint.x, position.y - self.startPoint.y));
    }
    self.maximumTravel = MAX(self.maximumTravel, hypot(point.x - self.startPoint.x, point.y - self.startPoint.y));
    double duration = touch.timestamp - self.startTime;
    if (!CGRectEqualToRect(self.sourceBounds, window.bounds) || !UIEdgeInsetsEqualToEdgeInsets(self.sourceInsets, window.safeAreaInsets) ||
        self.sourceOrientation != window.windowScene.interfaceOrientation) {
        [self interrupt:LCTapSyncResultGeometryChanged]; return;
    }
    if (touch.phase == UITouchPhaseCancelled || !LCTapSyncIsShortTap(duration, self.maximumTravel)) {
        self.candidate = nil; return;
    }
    if (touch.phase != UITouchPhaseEnded) return;
    self.candidate = nil;
    CGRect bounds = self.sourceBounds;
    if (!CGRectContainsPoint(bounds, point) || !CGRectContainsPoint(bounds, self.startPoint)) return;
    LCTapSyncSample sample = {(point.x - bounds.origin.x) / bounds.size.width,
        (point.y - bounds.origin.y) / bounds.size.height, bounds.size.width, bounds.size.height,
        NSProcessInfo.processInfo.systemUptime, duration, (int)self.sourceOrientation, (int)touch.tapCount};
    if (!LCTapSyncSampleIsValid(sample) || self.sequence == UINT64_MAX) return;
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self interrupt:LCTapSyncResultUnavailable]; });
    }];
    [host submitTap:LCTapSyncEncode(sample) session:self.session sequence:++self.sequence];
}
- (BOOL)sendPhase:(UITouchPhase)phase {
    UITouch *touch = self.syntheticTouch;
    if (!touch || !self.syntheticEvent) return NO;
    LCTapHIDEventRef hid = NULL;
    @try {
        [touch setPhase:phase];
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
        hid = LCTapCreateHID(touch);
        if (!hid) return NO;
        [touch _setHidEvent:hid];
        UIEvent *event = self.syntheticEvent;
        [event _clearTouches];
        [event _setHIDEvent:hid];
        [event _setTimestamp:touch.timestamp];
        [event _addTouch:touch forDelayedDelivery:NO];
        self.replaying = YES;
        [UIApplication.sharedApplication sendEvent:event];
        [event _clearTouches];
        return YES;
    } @catch (NSException *exception) {
        self.supported = NO;
        return NO;
    } @finally {
        self.replaying = NO;
        if (hid) CFRelease(hid);
    }
}
- (void)finishReplay:(LCTapSyncResult)result {
    if (self.syntheticTouch && self.syntheticTouch.phase != UITouchPhaseEnded && self.syntheticTouch.phase != UITouchPhaseCancelled) {
        [self sendPhase:UITouchPhaseCancelled];
    }
    self.syntheticTouch = nil;
    self.syntheticEvent = nil;
    void (^reply)(LCTapSyncResult) = self.replayReply;
    self.replayReply = nil;
    if (reply) reply(result);
    if (!self.supported) {
        id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
        [host readyWithVersion:1 canReplay:NO];
    }
}
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.session isEqualToString:session] || self.source) { reply(LCTapSyncResultStopped); return; }
        if (!self.supported) { reply(LCTapSyncResultUnsupported); return; }
        if (self.syntheticTouch || self.keyboardVisible) { reply(LCTapSyncResultBusy); return; }
        LCTapSyncSample sample;
        if (self.sequence == UINT64_MAX || sequence != self.sequence + 1 || !LCTapSyncDecode(tap, &sample) ||
            !LCTapSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
            reply(LCTapSyncResultExpired); return;
        }
        UIWindow *window = LCTapSyncGuestWindow();
        if (!window) { reply(LCTapSyncResultUnavailable); return; }
        if (!LCTapSyncCanMap(sample, window.bounds.size.width, window.bounds.size.height, (int)window.windowScene.interfaceOrientation)) {
            reply(LCTapSyncResultGeometryChanged); return;
        }
        @try {
            if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent])) { reply(LCTapSyncResultBusy); return; }
            CGPoint point = CGPointMake(CGRectGetMinX(window.bounds) + sample.x * window.bounds.size.width,
                                        CGRectGetMinY(window.bounds) + sample.y * window.bounds.size.height);
            UIView *hit = [window hitTest:point withEvent:nil];
            if (!hit || hit == window) { reply(LCTapSyncResultUnavailable); return; }
            // SwiftUI on iOS 18+ can return a gesture responder through a hit-test context.
            Class contextClass = NSClassFromString(@"_UIHitTestContext");
            SEL create = NSSelectorFromString(@"contextWithPoint:radius:");
            SEL find = NSSelectorFromString(@"_hitTestWithContext:");
            id responder = hit;
            if ([contextClass respondsToSelector:create] && [hit respondsToSelector:find]) {
                id context = ((id (*)(id, SEL, CGPoint, CGFloat))objc_msgSend)(contextClass, create, point, 0);
                for (UIView *view = hit; context && view; view = view.superview) {
                    if (![view respondsToSelector:find]) continue;
                    id match = ((id (*)(id, SEL, id))objc_msgSend)(view, find, context);
                    if (match) { responder = match; break; }
                }
            }
            UITouch *touch = [UITouch new];
            [touch setWindow:window];
            [touch setView:responder];
            [touch setTapCount:(NSUInteger)sample.tapCount];
            [touch _setLocationInWindow:point resetPrevious:YES];
            if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:responder];
            if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
            else if ([touch respondsToSelector:@selector(_setIsTapToClick:)]) [touch _setIsTapToClick:YES];
            self.sequence = sequence;
            self.syntheticTouch = touch;
            self.syntheticEvent = LCTapNewEvent();
            self.replayReply = reply;
            if (!self.syntheticEvent) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
            self.replayBounds = window.bounds;
            self.replayInsets = window.safeAreaInsets;
            self.replayOrientation = window.windowScene.interfaceOrientation;
            if (![self sendPhase:UITouchPhaseBegan]) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
            // Allow guest render loops to observe the down/up phases; never block the main run loop.
            NSTimeInterval hold = MAX(0.03, MIN(sample.duration, 0.12));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.syntheticTouch != touch || ![self.session isEqualToString:session]) return;
                if (!LCTapSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
                    [self finishReplay:LCTapSyncResultExpired]; return;
                }
                if (window != LCTapSyncGuestWindow() || !CGRectEqualToRect(window.bounds, self.replayBounds) ||
                    !UIEdgeInsetsEqualToEdgeInsets(window.safeAreaInsets, self.replayInsets) ||
                    window.windowScene.interfaceOrientation != self.replayOrientation) {
                    [self finishReplay:LCTapSyncResultGeometryChanged]; return;
                }
                BOOL delivered = [self sendPhase:UITouchPhaseEnded];
                [self finishReplay:delivered ? LCTapSyncResultAccepted : LCTapSyncResultUnsupported];
            });
        } @catch (NSException *exception) {
            self.supported = NO;
            if (self.replayReply) [self finishReplay:LCTapSyncResultUnsupported];
            else reply(LCTapSyncResultUnsupported);
        }
    });
}
@end

@implementation UIApplication (LCTapSyncHook)
- (void)lc_tapSync_sendEvent:(UIEvent *)event {
    [tapSyncClient observeEvent:event];
    [self lc_tapSync_sendEvent:event];
}
@end

__attribute__((constructor))
static void LCTapSyncClientInit(void) {
    if (!NSUserDefaults.isLiveProcess || !NSUserDefaults.lcGuestAppId) return;
    Class handler = NSClassFromString(@"LiveProcessHandler");
    if (![handler respondsToSelector:@selector(retrievedAppInfo)]) return;
    NSXPCListenerEndpoint *endpoint = [handler retrievedAppInfo][@"tapSyncEndpoint"];
    if (![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) return;
    swizzle(UIApplication.class, @selector(sendEvent:), @selector(lc_tapSync_sendEvent:));
    dispatch_async(dispatch_get_main_queue(), ^{
        tapSyncClient = [LCTapSyncClient new];
        tapSyncClient.supported = LCTapReplayAvailable();
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
        tapSyncClient.connection = connection;
        connection.exportedInterface = LCTapSyncGuestInterface();
        connection.exportedObject = tapSyncClient;
        connection.remoteObjectInterface = LCTapSyncHostInterface();
        void (^disconnected)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                tapSyncClient.session = nil;
                tapSyncClient.candidate = nil;
                [tapSyncClient finishReplay:LCTapSyncResultUnavailable];
            });
        };
        connection.interruptionHandler = disconnected;
        connection.invalidationHandler = disconnected;
        [connection resume];
        id<LCTapSyncHostProtocol> host = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { disconnected(); }];
        [host readyWithVersion:1 canReplay:tapSyncClient.supported];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{ [tapSyncClient interrupt:LCTapSyncResultUnavailable]; });
            }];
        }
        [center addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            tapSyncClient.keyboardVisible = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ [tapSyncClient interrupt:LCTapSyncResultBusy]; });
        }];
        [center addObserverForName:UIKeyboardDidHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            tapSyncClient.keyboardVisible = NO;
        }];
    });
}
