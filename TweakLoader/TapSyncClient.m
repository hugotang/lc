#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "../LiveContainer/utils.h"
#import "../MultitaskSupport/TapSyncProtocol.h"
#import "../MultitaskSupport/ProcessMetrics.h"
#import "TapSyncClientState.h"
#import "TapSyncReturnGesture.h"
#import "TapSyncWindow.h"

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

static UIWindow *LCTapSyncGuestWindowWithResult(LCTapSyncResult *result) {
    return LCTapSyncFindGuestWindow(UIApplication.sharedApplication.connectedScenes, result);
}
static UIWindow *LCTapSyncGuestWindow(void) { return LCTapSyncGuestWindowWithResult(NULL); }

@interface LCMultiTouchContact : NSObject
@property(nonatomic) UITouch *touch;
@property(nonatomic) uint32_t identifier;
@property(nonatomic) int tapCount;
@property(nonatomic) BOOL down;
@end
@implementation LCMultiTouchContact
@end

static BOOL LCTapHasRealTouches(UIEvent *event, LCTapSyncClientState *state) {
    if (state.hasPhysicalTouches) return YES;
    for (UITouch *touch in event.allTouches) {
        // Ownership survives finishReplay and a new session, including retained UIKit events.
        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled || [state ownsTouch:touch]) continue;
        return YES;
    }
    return NO;
}

static LCTapHIDEventRef LCTapCreateHID(UITouch *touch) {
    BOOL down = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
    uint32_t mask = 3 | (touch.phase == UITouchPhaseCancelled ? 0x80 : 0); // range, touch, optional cancel
    if (touch.phase == UITouchPhaseMoved) mask |= 4; // position changed
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
@property(nonatomic) NSXPCListenerEndpoint *hostEndpoint;
@property(nonatomic) LCTapSyncClientState *inputState;
@property(nonatomic) BOOL connectionRetryScheduled;
@property(nonatomic, copy) NSString *session;
@property(nonatomic) BOOL source, replaying, supported, keyboardVisible;
@property(nonatomic) BOOL suspended, resumeOnSource;
@property(nonatomic) BOOL syncReturnGesture;
@property(nonatomic) LCTapSyncReturnGesture *returnGesture;
@property(nonatomic) NSHashTable<UITouch *> *returnTouches;
@property(nonatomic, weak) UIWindow *returnWindow;
@property(nonatomic) CGRect returnBounds;
@property(nonatomic) UIEdgeInsets returnInsets;
@property(nonatomic) UIInterfaceOrientation returnOrientation;
@property(nonatomic) BOOL capturingReturnGesture;
@property(nonatomic) NSTimeInterval returnNotBefore;
@property(nonatomic) LCTapSyncResult suspensionResult;
@property(nonatomic) uint64_t physicalInputRevision;
@property(nonatomic) LCTapSyncMode mode;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) uint32_t contactCounter, activeContact;
@property(nonatomic) int sourceTapCount;
@property(nonatomic, strong) NSDictionary *pendingMove;
@property(nonatomic) BOOL moveFlushScheduled;
@property(nonatomic) NSUInteger moveFlushGeneration;
@property(nonatomic) NSTimeInterval lastMoveSent, replayTimeOffset;
@property(nonatomic) LCTouchSyncStream replayStream;
@property(nonatomic, weak) UITouch *candidate;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGRect sourceBounds;
@property(nonatomic) UIInterfaceOrientation sourceOrientation;
@property(nonatomic) UIEdgeInsets sourceInsets;
@property(nonatomic) NSTimeInterval startTime;
@property(nonatomic) double maximumTravel;
@property(nonatomic) UITouch *syntheticTouch;
@property(nonatomic) UIEvent *syntheticEvent;
@property(nonatomic) BOOL syntheticContactDown;
@property(nonatomic) CGRect replayBounds;
@property(nonatomic) UIEdgeInsets replayInsets;
@property(nonatomic) UIInterfaceOrientation replayOrientation;
@property(nonatomic, copy) void (^replayReply)(LCTapSyncResult);
@property(nonatomic) NSMutableArray<LCMultiTouchContact *> *sourceContacts, *replayContacts;
@property(nonatomic) NSDictionary *pendingFrame;
@property(nonatomic) LCMultiTouchSyncStream sourceMultiStream, replayMultiStream;
@property(nonatomic) UIEvent *multiEvent;
@property(nonatomic) NSUInteger multiReplayGeneration;
- (void)observeEvent:(UIEvent *)event;
- (void)interrupt:(LCTapSyncResult)reason;
- (void)interruptAfterCurrentEvent:(LCTapSyncResult)reason;
- (void)connectToHost;
- (void)connectionDidDisconnect:(NSXPCConnection *)connection;
- (void)observePhysicalInput:(UIEvent *)event;
- (void)suspendForPhysicalInput;
- (void)discardReturnGesture;
- (void)discardSourceReturnBeforeTime:(NSTimeInterval)time;
- (void)beginReturnGestureFromEvent:(UIEvent *)event;
- (LCTapSyncResult)resumeSource:(NSString *)session previousSession:(NSString *)previous inputRevision:(uint64_t)revision;
- (void)notifyPhysicalInputBegan:(BOOL)began timestamp:(NSTimeInterval)timestamp;
- (void)submitTapSample:(LCTapSyncSample)sample;
- (void)captureSourceEvent:(UIEvent *)event;
@end

static LCTapSyncClient *tapSyncClient;

@implementation LCTapSyncClient
- (instancetype)init {
    if ((self = [super init])) _inputState = [LCTapSyncClientState new];
    return self;
}
- (NSString *)session { return self.inputState.session; }
- (void)setSession:(NSString *)session {
    [self discardReturnGesture];
    self.inputState.session = session;
}
- (void)connectToHost {
    if (self.connection || !self.hostEndpoint) return;
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:self.hostEndpoint];
    self.connection = connection;
    connection.exportedInterface = LCTapSyncGuestInterface();
    connection.exportedObject = self;
    connection.remoteObjectInterface = LCTapSyncHostInterface();
    __weak typeof(self) weakSelf = self;
    __weak NSXPCConnection *weakConnection = connection;
    void (^disconnected)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf connectionDidDisconnect:weakConnection]; });
    };
    connection.interruptionHandler = disconnected;
    connection.invalidationHandler = disconnected;
    [connection resume];
    id<LCTapSyncHostProtocol> host = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { disconnected(); }];
    [host readyWithVersion:LCTapSyncProtocolVersion canReplay:self.supported];
}
- (void)connectionDidDisconnect:(NSXPCConnection *)connection {
    // An old connection can report invalidation after its replacement is already ready.
    if (!connection || self.connection != connection) return;
    self.connection = nil;
    self.session = nil;
    [self discardCapture];
    [self finishReplay:LCTapSyncResultUnavailable];
    [connection invalidate];
    if (self.connectionRetryScheduled) return;
    NSTimeInterval delay = [self.inputState nextConnectionRetryDelay];
    if (delay <= 0) return;
    self.connectionRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.connectionRetryScheduled = NO;
        [self connectToHost]; // Reconnect transport only. Input stays paused until a fresh start.
    });
}
- (void)samplePerformanceWithReply:(void (^)(NSDictionary *))reply {
    // NSXPC calls this on its service queue. Sampling does not use the guest's UI loop.
    reply(LCReadProcessMetrics());
}
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode resumeOnSource:(BOOL)resumeOnSource
         syncReturnGesture:(BOOL)syncReturnGesture
                 reply:(void (^)(LCTapSyncResult))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable); return; }
        [self.inputState resetConnectionRecovery];
        self.session = nil;
        [self finishReplay:LCTapSyncResultStopped];
        [self discardCapture];
        if (mode != LCTapSyncModeTapsOnly && mode != LCTapSyncModeSingleFinger && mode != LCTapSyncModeTwoFingers) {
            reply(LCTapSyncResultUnsupported); return;
        }
        if (![session isKindOfClass:NSString.class] || session.length != 36) {
            reply(LCTapSyncResultInvalidGesture); return;
        }
        if (self.keyboardVisible) { reply(LCTapSyncResultKeyboardVisible); return; }
        LCTapSyncResult windowResult;
        UIWindow *window = LCTapSyncGuestWindowWithResult(&windowResult);
        if (!window) { reply(windowResult); return; }
        if (window.bounds.size.width < 1 || window.bounds.size.height < 1 || window.windowScene.interfaceOrientation == UIInterfaceOrientationUnknown) {
            reply(LCTapSyncResultWindowNotReady); return;
        }
        if (!source && !self.supported) { reply(LCTapSyncResultUnsupported); return; }
        @try {
            if (self.inputState.hasPhysicalTouches || ([UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)] &&
                LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState))) {
                reply(LCTapSyncResultPhysicalTouch); return;
            }
        } @catch (NSException *exception) { reply(LCTapSyncResultUnsupported); return; }
        self.session = session;
        self.source = source;
        self.mode = mode;
        self.suspended = NO;
        self.suspensionResult = LCTapSyncResultSuspended;
        self.resumeOnSource = resumeOnSource;
        self.syncReturnGesture = syncReturnGesture;
        self.returnNotBefore = 0;
        self.physicalInputRevision = 0;
        self.sequence = 0;
        self.contactCounter = 0;
        self.replayStream = (LCTouchSyncStream){0};
        self.replayMultiStream = (LCMultiTouchSyncStream){0};
        reply(LCTapSyncResultAccepted);
    });
}
- (void)suspendSession:(NSString *)session reply:(void (^)(LCTapSyncResult, BOOL, uint64_t))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable, NO, 0); return; }
        if (![self.session isEqualToString:session]) { reply(LCTapSyncResultStopped, NO, 0); return; }
        if (!self.suspended) self.suspensionResult = LCTapSyncResultSuspended;
        self.suspended = YES;
        if (!self.returnGesture) [self discardCapture];
        [self finishReplay:LCTapSyncResultSuspended];
        if (!self.supported && !self.source) { reply(LCTapSyncResultUnsupported, NO, self.physicalInputRevision); return; }
        if (self.keyboardVisible) { reply(LCTapSyncResultKeyboardVisible, NO, self.physicalInputRevision); return; }
        BOOL touching = self.inputState.hasPhysicalTouches;
        @try {
            if ([UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)]) {
                UIEvent *event = [UIApplication.sharedApplication _touchesEvent];
                [self observePhysicalInput:event];
                touching = LCTapHasRealTouches(event, self.inputState);
            }
        } @catch (NSException *exception) { reply(LCTapSyncResultUnsupported, NO, self.physicalInputRevision); return; }
        if (![self.session isEqualToString:session]) { reply(LCTapSyncResultStopped, NO, self.physicalInputRevision); return; }
        reply(LCTapSyncResultAccepted, touching, self.physicalInputRevision);
    });
}
- (void)discardSourceReturn:(NSString *)session beforeTime:(NSTimeInterval)time {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender || ![self.session isEqualToString:session] || !isfinite(time) || time < 0) return;
        [self discardSourceReturnBeforeTime:time];
    });
}
- (void)discardSourceReturnBeforeTime:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0) return;
    self.returnNotBefore = MAX(self.returnNotBefore, time);
    if (self.returnGesture && self.returnGesture.beganAt <= time) {
        [self discardReturnGesture];
        [self discardCapture];
        [self notifyPhysicalInputBegan:NO timestamp:NSProcessInfo.processInfo.systemUptime];
    }
}
- (void)resumeSourceSession:(NSString *)session previousSession:(NSString *)previous inputRevision:(uint64_t)revision
                      reply:(void (^)(LCTapSyncResult))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable); return; }
        @try { reply([self resumeSource:session previousSession:previous inputRevision:revision]); }
        @catch (NSException *exception) { [self interrupt:LCTapSyncResultUnsupported]; reply(LCTapSyncResultUnsupported); }
    });
}
- (LCTapSyncResult)resumeSource:(NSString *)session previousSession:(NSString *)previous inputRevision:(uint64_t)revision {
    if (!self.suspended || !self.source || !self.resumeOnSource || !self.syncReturnGesture || ![self.session isEqualToString:previous]) {
        return LCTapSyncResultStopped;
    }
    if (![session isKindOfClass:NSString.class] || session.length != 36 || !revision || self.returnGesture.revision != revision) {
        return LCTapSyncResultInvalidGesture;
    }
    if (![self.returnGesture isFreshAtTime:NSProcessInfo.processInfo.systemUptime]) return LCTapSyncResultExpired;
    if (self.keyboardVisible) return LCTapSyncResultKeyboardVisible;
    LCTapSyncResult result;
    UIWindow *window = LCTapSyncGuestWindowWithResult(&result);
    if (!window) return result;
    if (window != self.returnWindow || !CGRectEqualToRect(window.bounds, self.returnBounds) ||
        !UIEdgeInsetsEqualToEdgeInsets(window.safeAreaInsets, self.returnInsets) ||
        window.windowScene.interfaceOrientation != self.returnOrientation) return LCTapSyncResultGeometryChanged;
    if ([UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)]) {
        [self observePhysicalInput:[UIApplication.sharedApplication _touchesEvent]];
    }
    if (![self.session isEqualToString:previous] || !self.returnGesture || self.returnGesture.revision != revision) return LCTapSyncResultStopped;
    if ([self.inputState hasPhysicalTouchesOtherThan:self.returnTouches]) return LCTapSyncResultPhysicalTouch;
    if (self.mode == LCTapSyncModeSingleFinger) [self flushPendingMove];
    else if (self.mode == LCTapSyncModeTwoFingers) [self flushPendingFrame];
    if (!self.returnGesture || ![self.returnGesture isFreshAtTime:NSProcessInfo.processInfo.systemUptime]) return LCTapSyncResultExpired;
    // Register the new identifier without discarding the source's real contact,
    // original hit/capture state, pending final move or short return buffer.
    NSArray<NSDictionary *> *packets = self.returnGesture.packets;
    self.inputState.session = session;
    self.sequence = packets.count;
    self.physicalInputRevision = 0;
    self.suspended = NO;
    [self discardReturnGesture];
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.session isEqualToString:session]) [self interrupt:LCTapSyncResultUnavailable];
        });
    }];
    [host submitSourceReturn:packets session:session];
    return LCTapSyncResultAccepted;
}
- (void)stopSession:(NSString *)session {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) return;
        if (![self.session isEqualToString:session]) return;
        self.session = nil;
        [self discardCapture];
        [self finishReplay:LCTapSyncResultStopped];
    });
}
- (void)interrupt:(LCTapSyncResult)reason {
    NSString *session = self.session;
    BOOL hadReturnGesture = self.returnGesture != nil;
    // Keep observation alive for a geometry suspension; the host either stops it
    // or restarts after rotation. Capture/replay are disabled in either case.
    if (reason == LCTapSyncResultGeometryChanged) { self.suspended = YES; self.suspensionResult = reason; }
    else self.session = nil;
    [self discardReturnGesture];
    [self discardCapture];
    [self finishReplay:reason];
    if (reason == LCTapSyncResultGeometryChanged && hadReturnGesture) [self notifyPhysicalInputBegan:NO timestamp:NSProcessInfo.processInfo.systemUptime];
    if (session) {
        id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
        [host interruptSession:session reason:reason];
    }
}
- (void)interruptAfterCurrentEvent:(LCTapSyncResult)reason {
    dispatch_block_t action = [self.inputState actionForCurrentSession:^{ [self interrupt:reason]; }];
    if (action) dispatch_async(dispatch_get_main_queue(), action);
}
- (void)discardCapture {
    self.candidate = nil;
    self.activeContact = 0;
    self.pendingMove = nil;
    self.moveFlushScheduled = NO;
    self.moveFlushGeneration += 1;
    self.sourceContacts = nil;
    self.pendingFrame = nil;
    self.sourceMultiStream = (LCMultiTouchSyncStream){0};
}
- (void)discardReturnGesture {
    self.returnGesture = nil;
    self.returnTouches = nil;
    self.returnWindow = nil;
    self.capturingReturnGesture = NO;
}
- (void)beginReturnGestureFromEvent:(UIEvent *)event {
    if (!self.source || !self.suspended || !self.resumeOnSource || !self.syncReturnGesture || !self.session || self.keyboardVisible) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.returnGesture && ![self.returnGesture isFreshAtTime:now]) {
        [self discardReturnGesture];
        [self discardCapture];
    }
    BOOL hadReturnGesture = self.returnGesture != nil;
    UIWindow *window = LCTapSyncGuestWindow();
    if (!window) return;
    NSMutableArray<UITouch *> *touches = [NSMutableArray array];
    for (UITouch *touch in event.allTouches) {
        if ([self.inputState ownsTouch:touch]) continue;
        if (touch.type != UITouchTypeDirect || touch.window != window) return;
        [touches addObject:touch];
    }
    BOOL newBegin = NO;
    NSTimeInterval beganAt = 0;
    for (UITouch *touch in touches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        if (!self.returnGesture && (touch.timestamp <= self.returnNotBefore || !CGRectContainsPoint(window.bounds, [touch locationInView:window]))) return;
        newBegin = YES;
        beganAt = MAX(beganAt, touch.timestamp);
    }
    if (hadReturnGesture && !self.inputState.hasPhysicalTouches && newBegin && self.returnGesture.packets.count) {
        [self discardReturnGesture];
        [self discardCapture];
    }
    if (!self.returnGesture) {
        if (!newBegin || touches.count == 0 || (self.mode != LCTapSyncModeTwoFingers && touches.count != 1)) return;
        for (UITouch *touch in touches) if (touch.phase != UITouchPhaseBegan) return;
        [self discardCapture];
        self.returnTouches = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
        self.returnGesture = [[LCTapSyncReturnGesture alloc] initWithMode:self.mode revision:self.physicalInputRevision + 1 atTime:beganAt];
        LCTapSyncReturnGesture *gesture = self.returnGesture;
        if (!gesture || ![gesture isFreshAtTime:now]) { [self discardReturnGesture]; return; }
        NSString *session = self.session;
        __weak typeof(self) weakSelf = self;
        NSTimeInterval expiresIn = MAX(0, 0.75 - (now - beganAt));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(expiresIn * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) client = weakSelf;
            if (client.returnGesture != gesture || ![client.session isEqualToString:session]) return;
            [client discardReturnGesture];
            [client discardCapture];
            [client notifyPhysicalInputBegan:NO timestamp:NSProcessInfo.processInfo.systemUptime];
        });
        self.returnWindow = window;
        self.returnBounds = window.bounds;
        self.returnInsets = window.safeAreaInsets;
        self.returnOrientation = window.windowScene.interfaceOrientation;
    }
    for (UITouch *touch in touches) if (touch.phase == UITouchPhaseBegan) [self.returnTouches addObject:touch];
}
- (void)submitTapSample:(LCTapSyncSample)sample {
    if (self.capturingReturnGesture || (self.suspended && self.returnGesture)) {
        if (![self.returnGesture appendTap:LCTapSyncEncode(sample)]) [self interrupt:LCTapSyncResultBusy];
        return;
    }
    if (!self.session || !self.source || self.suspended || self.sequence == UINT64_MAX) return;
    NSString *session = self.session;
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.session isEqualToString:session]) [self interrupt:LCTapSyncResultUnavailable];
        });
    }];
    [host submitTap:LCTapSyncEncode(sample) session:self.session sequence:++self.sequence];
}
- (void)submitTouchSample:(LCTouchSyncSample)sample {
    if (!self.session || !self.source) return;
    if (!LCTouchSyncSampleIsValid(sample) || self.sequence == UINT64_MAX) {
        [self interrupt:LCTapSyncResultInvalidGesture]; return;
    }
    if (self.capturingReturnGesture || (self.suspended && self.returnGesture)) {
        if (![self.returnGesture appendTouch:LCTouchSyncEncode(sample)]) [self interrupt:LCTapSyncResultBusy];
        self.lastMoveSent = NSProcessInfo.processInfo.systemUptime;
        return;
    }
    if (self.suspended) return;
    NSString *session = self.session;
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.session isEqualToString:session]) [self interrupt:LCTapSyncResultUnavailable];
        });
    }];
    self.lastMoveSent = NSProcessInfo.processInfo.systemUptime;
    [host submitTouch:LCTouchSyncEncode(sample) session:session sequence:++self.sequence];
}
- (void)flushPendingMove {
    NSDictionary *pending = self.pendingMove;
    self.pendingMove = nil;
    self.moveFlushScheduled = NO;
    self.moveFlushGeneration += 1;
    LCTouchSyncSample sample = {0};
    if (LCTouchSyncDecode(pending, &sample)) [self submitTouchSample:sample];
}
- (void)captureLiveTouch:(UITouch *)touch point:(CGPoint)point {
    LCTouchSyncPhase phase;
    switch (touch.phase) {
        case UITouchPhaseBegan: phase = LCTouchSyncPhaseBegan; break;
        case UITouchPhaseMoved: phase = LCTouchSyncPhaseMoved; break;
        case UITouchPhaseEnded: phase = LCTouchSyncPhaseEnded; break;
        case UITouchPhaseCancelled: phase = LCTouchSyncPhaseCancelled; break;
        default: return;
    }
    if (phase == LCTouchSyncPhaseBegan) {
        if (!CGRectContainsPoint(self.sourceBounds, point)) { [self discardCapture]; return; }
        if (self.contactCounter == UINT32_MAX) { [self interrupt:LCTapSyncResultStopped]; return; }
        self.activeContact = ++self.contactCounter;
        self.sourceTapCount = (int)MAX(1, MIN(touch.tapCount, 10));
    }
    CGRect bounds = self.sourceBounds;
    LCTouchSyncSample sample = {(point.x - bounds.origin.x) / bounds.size.width,
        (point.y - bounds.origin.y) / bounds.size.height, bounds.size.width, bounds.size.height,
        touch.timestamp, self.activeContact, (int)self.sourceOrientation, self.sourceTapCount, phase};
    if (!LCTouchSyncSampleIsValid(sample)) { [self interrupt:LCTapSyncResultInvalidGesture]; return; }
    if (phase != LCTouchSyncPhaseMoved) {
        // Flush a final move before the release; cancelling never turns into an artificial tap.
        [self flushPendingMove];
        [self submitTouchSample:sample];
        if (phase == LCTouchSyncPhaseEnded || phase == LCTouchSyncPhaseCancelled) [self discardCapture];
        return;
    }
    self.pendingMove = LCTouchSyncEncode(sample);
    NSTimeInterval delay = 1.0 / 60.0 - (NSProcessInfo.processInfo.systemUptime - self.lastMoveSent);
    if (delay <= 0) { [self flushPendingMove]; return; }
    if (self.moveFlushScheduled) return;
    self.moveFlushScheduled = YES;
    NSUInteger generation = self.moveFlushGeneration;
    NSString *session = self.session;
    // A one-shot flush exists only while physical moves arrive. Stationary holds and idle sessions do not poll.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.moveFlushGeneration == generation && [self.session isEqualToString:session]) [self flushPendingMove];
    });
}
- (void)submitMultiFrame:(LCMultiTouchSyncFrame)frame {
    if (!self.session || !self.source || self.mode != LCTapSyncModeTwoFingers) return;
    if (!LCMultiTouchSyncFrameIsValid(frame) || self.sequence == UINT64_MAX) {
        [self interrupt:LCTapSyncResultInvalidGesture]; return;
    }
    if (self.capturingReturnGesture || (self.suspended && self.returnGesture)) {
        if (![self.returnGesture appendFrame:LCMultiTouchSyncEncode(frame)]) [self interrupt:LCTapSyncResultBusy];
        self.lastMoveSent = NSProcessInfo.processInfo.systemUptime;
        return;
    }
    if (self.suspended) return;
    NSString *session = self.session;
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.session isEqualToString:session]) [self interrupt:LCTapSyncResultUnavailable];
        });
    }];
    self.lastMoveSent = NSProcessInfo.processInfo.systemUptime;
    [host submitTouchFrame:LCMultiTouchSyncEncode(frame) session:session sequence:++self.sequence];
}
- (void)flushPendingFrame {
    NSDictionary *pending = self.pendingFrame;
    self.pendingFrame = nil;
    self.moveFlushScheduled = NO;
    self.moveFlushGeneration += 1;
    LCMultiTouchSyncFrame frame = {0};
    if (LCMultiTouchSyncDecode(pending, &frame)) [self submitMultiFrame:frame];
}
- (void)captureMultiTouchEvent:(UIEvent *)event touches:(NSSet<UITouch *> *)touches {
    if (!touches.count && !self.sourceContacts.count) return;
    UIWindow *window = LCTapSyncGuestWindow();
    if (!window || self.keyboardVisible) { [self interrupt:LCTapSyncResultUnavailable]; return; }
    NSMutableArray<LCMultiTouchContact *> *contacts = self.sourceContacts.mutableCopy ?: [NSMutableArray array];
    unsigned down = 0;
    for (UITouch *touch in touches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) down++;
        if (touch.type != UITouchTypeDirect || touch.window != window) { [self interrupt:LCTapSyncResultInvalidGesture]; return; }
        BOOL known = NO;
        for (LCMultiTouchContact *contact in contacts) if (contact.touch == touch) { known = YES; break; }
        if (known) continue;
        // UIKit can still include a previously released contact in a later event.
        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) continue;
        if (touch.phase != UITouchPhaseBegan || self.contactCounter == UINT32_MAX) {
            [self interrupt:LCTapSyncResultInvalidGesture]; return;
        }
        LCMultiTouchContact *contact = [LCMultiTouchContact new];
        contact.touch = touch;
        contact.identifier = ++self.contactCounter;
        contact.tapCount = (int)MAX(1, MIN(touch.tapCount, 10));
        [contacts addObject:contact];
    }
    if (down > LCMultiTouchSyncMaximumContacts || contacts.count > LCMultiTouchSyncMaximumFrameContacts) {
        [self interrupt:LCTapSyncResultTooManyTouches]; return;
    }
    if (!contacts.count) return;
    if (!self.sourceContacts.count) {
        self.sourceBounds = window.bounds;
        self.sourceInsets = window.safeAreaInsets;
        self.sourceOrientation = window.windowScene.interfaceOrientation;
    }
    if (!CGRectEqualToRect(self.sourceBounds, window.bounds) || !UIEdgeInsetsEqualToEdgeInsets(self.sourceInsets, window.safeAreaInsets) ||
        self.sourceOrientation != window.windowScene.interfaceOrientation) { [self interrupt:LCTapSyncResultGeometryChanged]; return; }
    LCMultiTouchSyncFrame frame = {.width = window.bounds.size.width, .height = window.bounds.size.height,
        .timestamp = event.timestamp, .orientation = (int)self.sourceOrientation, .count = (unsigned)contacts.count};
    NSMutableArray *remaining = [NSMutableArray array];
    BOOL changed = NO;
    for (unsigned i = 0; i < frame.count; i++) {
        LCMultiTouchContact *contact = contacts[i];
        UITouch *touch = contact.touch;
        if (![touches containsObject:touch]) { [self interrupt:LCTapSyncResultInvalidGesture]; return; }
        LCMultiTouchSyncPhase phase;
        switch (touch.phase) {
            case UITouchPhaseBegan: phase = LCMultiTouchSyncPhaseBegan; break;
            case UITouchPhaseMoved: phase = LCMultiTouchSyncPhaseMoved; break;
            case UITouchPhaseEnded: phase = LCMultiTouchSyncPhaseEnded; break;
            case UITouchPhaseCancelled: phase = LCMultiTouchSyncPhaseCancelled; break;
            case UITouchPhaseStationary: phase = LCMultiTouchSyncPhaseStationary; break;
            default: [self interrupt:LCTapSyncResultInvalidGesture]; return;
        }
        CGPoint point = [touch locationInView:window];
        frame.contacts[i] = (LCMultiTouchSyncContact){(point.x - window.bounds.origin.x) / frame.width,
            (point.y - window.bounds.origin.y) / frame.height, contact.identifier, contact.tapCount, phase};
        if (LCMultiTouchSyncIsDown(frame.contacts[i])) [remaining addObject:contact];
        if (phase != LCMultiTouchSyncPhaseStationary) changed = YES;
    }
    if (!changed) return;
    LCMultiTouchSyncStream stream = self.sourceMultiStream;
    if (!LCMultiTouchSyncAdvance(&stream, frame)) { [self interrupt:LCTapSyncResultInvalidGesture]; return; }
    self.sourceMultiStream = stream;
    self.sourceContacts = remaining;
    if (LCMultiTouchSyncHasBoundary(frame)) {
        [self flushPendingFrame];
        [self submitMultiFrame:frame];
        return;
    }
    LCMultiTouchSyncFrame previous;
    if (LCMultiTouchSyncDecode(self.pendingFrame, &previous) && !LCMultiTouchSyncCoalesce(previous, &frame)) [self flushPendingFrame];
    self.pendingFrame = LCMultiTouchSyncEncode(frame);
    NSTimeInterval delay = 1.0 / 60.0 - (NSProcessInfo.processInfo.systemUptime - self.lastMoveSent);
    if (delay <= 0) { [self flushPendingFrame]; return; }
    if (self.moveFlushScheduled) return;
    self.moveFlushScheduled = YES;
    NSUInteger generation = self.moveFlushGeneration;
    NSString *session = self.session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.moveFlushGeneration == generation && [self.session isEqualToString:session]) [self flushPendingFrame];
    });
}
- (void)observeEvent:(UIEvent *)event {
    if (!self.replaying && event.type == UIEventTypeTouches) {
        uint64_t previousReturn = self.returnGesture.revision;
        uint64_t previousInput = self.physicalInputRevision;
        [self beginReturnGestureFromEvent:event];
        [self observePhysicalInput:event];
        // A suspension snapshot can observe this real down before sendEvent.
        // Still publish its newly captured return token exactly once.
        if (self.returnGesture && self.returnGesture.revision != previousReturn && self.physicalInputRevision == previousInput) {
            [self notifyPhysicalInputBegan:YES timestamp:self.returnGesture.beganAt];
        }
    }
    if (!self.session || self.replaying) return;
    if (event.type == UIEventTypePresses) { [self interrupt:LCTapSyncResultBusy]; return; }
    if (event.type != UIEventTypeTouches) return;
    if (self.suspended) {
        if (!self.source && !self.resumeOnSource && LCTapHasRealTouches(event, self.inputState)) [self interrupt:LCTapSyncResultPhysicalTouch];
        if (self.source && self.returnGesture) {
            self.capturingReturnGesture = YES;
            [self captureSourceEvent:event];
            self.capturingReturnGesture = NO;
        }
        return;
    }
    if (!self.source) {
        if (LCTapHasRealTouches(event, self.inputState)) [self suspendForPhysicalInput];
        return;
    }
    [self captureSourceEvent:event];
}
- (void)captureSourceEvent:(UIEvent *)event {
    NSMutableSet<UITouch *> *touches = [NSMutableSet set];
    for (UITouch *touch in event.allTouches) if (![self.inputState ownsTouch:touch]) [touches addObject:touch];
    if (self.mode == LCTapSyncModeTwoFingers) { [self captureMultiTouchEvent:event touches:touches]; return; }
    if (touches.count != 1) {
        if (self.mode == LCTapSyncModeSingleFinger && (touches.count > 1 || self.activeContact)) {
            [self interrupt:touches.count > 1 ? LCTapSyncResultMultipleTouches : LCTapSyncResultInvalidGesture];
        } else [self discardCapture];
        return;
    }
    UITouch *touch = touches.anyObject;
    UIWindow *window = touch.window;
    if (touch.type != UITouchTypeDirect || !window || window != LCTapSyncGuestWindow() || self.keyboardVisible) {
        if (self.activeContact) [self interrupt:LCTapSyncResultInvalidGesture];
        else [self discardCapture];
        return;
    }
    CGPoint point = [touch locationInView:window];
    if (touch.phase == UITouchPhaseBegan) {
        if (self.activeContact) { [self interrupt:LCTapSyncResultMultipleTouches]; return; }
        self.candidate = touch;
        self.startPoint = point;
        self.startTime = touch.timestamp;
        self.sourceBounds = window.bounds;
        self.sourceInsets = window.safeAreaInsets;
        self.sourceOrientation = window.windowScene.interfaceOrientation;
        self.maximumTravel = 0;
        if (self.mode == LCTapSyncModeSingleFinger) [self captureLiveTouch:touch point:point];
        return;
    }
    if (self.candidate != touch) {
        if (self.activeContact) [self interrupt:LCTapSyncResultInvalidGesture];
        return;
    }
    if (!CGRectEqualToRect(self.sourceBounds, window.bounds) || !UIEdgeInsetsEqualToEdgeInsets(self.sourceInsets, window.safeAreaInsets) ||
        self.sourceOrientation != window.windowScene.interfaceOrientation) {
        [self interrupt:LCTapSyncResultGeometryChanged]; return;
    }
    if (self.mode == LCTapSyncModeSingleFinger) { [self captureLiveTouch:touch point:point]; return; }
    for (UITouch *sample in [event coalescedTouchesForTouch:touch] ?: @[touch]) {
        CGPoint position = [sample locationInView:window];
        self.maximumTravel = MAX(self.maximumTravel, hypot(position.x - self.startPoint.x, position.y - self.startPoint.y));
    }
    self.maximumTravel = MAX(self.maximumTravel, hypot(point.x - self.startPoint.x, point.y - self.startPoint.y));
    double duration = touch.timestamp - self.startTime;
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
    [self submitTapSample:sample];
}
- (void)observePhysicalInput:(UIEvent *)event {
    BOOL previous = self.inputState.hasPhysicalTouches;
    BOOL began = NO;
    NSTimeInterval beganAt = 0;
    UIWindow *guest = nil;
    for (UITouch *touch in event.allTouches) {
        if ([self.inputState ownsTouch:touch]) continue;
        BOOL down = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
        BOOL changed = [self.inputState observePhysicalTouch:touch active:down];
        if (changed && down && self.session && touch.phase == UITouchPhaseBegan && touch.type == UITouchTypeDirect) {
            if (!guest) guest = LCTapSyncGuestWindow();
            if (guest && touch.window == guest) { began = YES; beganAt = MAX(beganAt, touch.timestamp); }
        }
    }
    BOOL touching = self.inputState.hasPhysicalTouches;
    if (!self.session || (previous == touching && !began)) return;
    if (self.physicalInputRevision == UINT64_MAX) { [self interrupt:LCTapSyncResultStopped]; return; }
    if (!self.suspended && !self.resumeOnSource) return;
    [self notifyPhysicalInputBegan:began timestamp:began ? beganAt : NSProcessInfo.processInfo.systemUptime];
}
- (void)notifyPhysicalInputBegan:(BOOL)began timestamp:(NSTimeInterval)timestamp {
    if (!self.session || self.physicalInputRevision == UINT64_MAX) return;
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [host physicalInputChanged:self.inputState.hasPhysicalTouches began:began session:self.session revision:++self.physicalInputRevision
                    timestamp:timestamp returnRevision:self.returnGesture.revision];
}
- (void)suspendForPhysicalInput {
    if (!self.resumeOnSource) { [self interrupt:LCTapSyncResultPhysicalTouch]; return; }
    self.suspended = YES;
    self.suspensionResult = LCTapSyncResultSuspended;
    // A replay check can see a real down before sendEvent observes it. Remember
    // that contact now so its eventual release cannot leave the host waiting.
    uint64_t previousRevision = self.physicalInputRevision;
    @try {
        [self observePhysicalInput:[UIApplication.sharedApplication _touchesEvent]];
    } @catch (NSException *exception) {
        [self interrupt:LCTapSyncResultUnsupported]; return;
    }
    [self discardCapture];
    [self finishReplay:LCTapSyncResultSuspended];
    if (!self.session || self.physicalInputRevision != previousRevision) return;
    // An already-observed down has sent its begin. Repeating only its state avoids
    // resetting a newer source-return gesture on another process's connection.
    if (self.physicalInputRevision == UINT64_MAX) { [self interrupt:LCTapSyncResultStopped]; return; }
    id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [host physicalInputChanged:self.inputState.hasPhysicalTouches began:NO session:self.session revision:++self.physicalInputRevision
                    timestamp:NSProcessInfo.processInfo.systemUptime returnRevision:0];
}
- (BOOL)sendPhase:(UITouchPhase)phase {
    return [self sendPhase:phase timestamp:MAX(NSProcessInfo.processInfo.systemUptime, self.syntheticTouch.timestamp)];
}
- (BOOL)sendPhase:(UITouchPhase)phase timestamp:(NSTimeInterval)timestamp {
    UITouch *touch = self.syntheticTouch;
    if (!touch || !self.syntheticEvent) return NO;
    LCTapHIDEventRef hid = NULL;
    @try {
        [touch setPhase:phase];
        [touch setTimestamp:timestamp];
        hid = LCTapCreateHID(touch);
        if (!hid) return NO;
        [touch _setHidEvent:hid];
        UIEvent *event = self.syntheticEvent;
        [event _clearTouches];
        [event _setHIDEvent:hid];
        [event _setTimestamp:touch.timestamp];
        [event _addTouch:touch forDelayedDelivery:NO];
        self.replaying = YES;
        if (phase == UITouchPhaseBegan) self.syntheticContactDown = YES;
        [UIApplication.sharedApplication sendEvent:event];
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) self.syntheticContactDown = NO;
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
    // The phase setter can succeed even when delivery fails. Track delivery separately so a failed up still cancels.
    if (self.syntheticTouch && self.syntheticContactDown) {
        [self sendPhase:UITouchPhaseCancelled];
    }
    self.syntheticContactDown = NO;
    self.syntheticTouch = nil;
    self.syntheticEvent = nil;
    [self cancelMultiReplay];
    LCTouchSyncStream stream = self.replayStream;
    stream.contact = 0;
    self.replayStream = stream;
    void (^reply)(LCTapSyncResult) = self.replayReply;
    self.replayReply = nil;
    if (reply) reply(result);
    if (!self.supported) {
        id<LCTapSyncHostProtocol> host = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
        [host readyWithVersion:LCTapSyncProtocolVersion canReplay:NO];
    }
}
- (UITouch *)newSyntheticTouchInWindow:(UIWindow *)window point:(CGPoint)point tapCount:(NSUInteger)tapCount {
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit || hit == window) return nil;
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
    [touch setTapCount:tapCount];
    [touch _setLocationInWindow:point resetPrevious:YES];
    if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:responder];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
    else if (self.mode == LCTapSyncModeTapsOnly && [touch respondsToSelector:@selector(_setIsTapToClick:)]) [touch _setIsTapToClick:YES];
    [self.inputState rememberSyntheticTouch:touch];
    return touch;
}
- (LCTapSyncResult)createSyntheticTouchInWindow:(UIWindow *)window point:(CGPoint)point tapCount:(NSUInteger)tapCount {
    UITouch *touch = [self newSyntheticTouchInWindow:window point:point tapCount:tapCount];
    if (!touch) return LCTapSyncResultWindowNotReady;
    UIEvent *event = LCTapNewEvent();
    if (!event) return LCTapSyncResultUnsupported;
    self.syntheticTouch = touch;
    self.syntheticEvent = event;
    self.syntheticContactDown = NO;
    self.replayBounds = window.bounds;
    self.replayInsets = window.safeAreaInsets;
    self.replayOrientation = window.windowScene.interfaceOrientation;
    return LCTapSyncResultAccepted;
}
- (BOOL)replayWindowIsUnchanged:(UIWindow *)window {
    return window && window == LCTapSyncGuestWindow() && CGRectEqualToRect(window.bounds, self.replayBounds) &&
        UIEdgeInsetsEqualToEdgeInsets(window.safeAreaInsets, self.replayInsets) &&
        window.windowScene.interfaceOrientation == self.replayOrientation;
}
- (void)replayTouch:(NSDictionary *)packet session:(NSString *)session sequence:(uint64_t)sequence
             reply:(void (^)(LCTapSyncResult))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable); return; }
        if (![self.session isEqualToString:session] || self.source) { reply(LCTapSyncResultStopped); return; }
        if (self.mode != LCTapSyncModeSingleFinger) { reply(LCTapSyncResultInvalidGesture); return; }
        if (self.suspended) { reply(self.suspensionResult); return; }
        if (self.replayReply) { reply(LCTapSyncResultBusy); return; }
        self.replayReply = reply;
        if (!self.supported) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
        if (self.keyboardVisible) { [self finishReplay:LCTapSyncResultKeyboardVisible]; return; }
        LCTouchSyncSample sample = {0};
        if (self.sequence == UINT64_MAX || sequence != self.sequence + 1 || !LCTouchSyncDecode(packet, &sample) ||
            !LCTouchSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
            [self finishReplay:LCTapSyncResultExpired]; return;
        }
        LCTouchSyncStream stream = self.replayStream;
        if (!LCTouchSyncAdvance(&stream, sample)) { [self finishReplay:LCTapSyncResultInvalidGesture]; return; }
        LCTapSyncResult windowResult;
        UIWindow *window = LCTapSyncGuestWindowWithResult(&windowResult);
        if (!window) { [self finishReplay:windowResult]; return; }
        if (!LCTouchSyncCanMap(sample, window.bounds.size.width, window.bounds.size.height, (int)window.windowScene.interfaceOrientation)) {
            [self finishReplay:LCTapSyncResultGeometryChanged]; return;
        }
        @try {
            if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState)) { [self suspendForPhysicalInput]; return; }
            CGPoint point = CGPointMake(CGRectGetMinX(window.bounds) + sample.x * window.bounds.size.width,
                                        CGRectGetMinY(window.bounds) + sample.y * window.bounds.size.height);
            if (sample.phase == LCTouchSyncPhaseBegan) {
                if (self.syntheticTouch) { [self finishReplay:LCTapSyncResultInvalidGesture]; return; }
                LCTapSyncResult prepared = [self createSyntheticTouchInWindow:window point:point tapCount:(NSUInteger)sample.tapCount];
                if (prepared != LCTapSyncResultAccepted) { [self finishReplay:prepared]; return; }
                self.replayTimeOffset = NSProcessInfo.processInfo.systemUptime - sample.timestamp;
            } else if (!self.syntheticTouch || self.syntheticTouch.window != window) {
                [self finishReplay:LCTapSyncResultGeometryChanged]; return;
            }
            self.sequence = sequence;
            UITouch *touch = self.syntheticTouch;
            NSTimeInterval timestamp = sample.timestamp + self.replayTimeOffset;
            void (^deliver)(void) = ^{
                if (self.syntheticTouch != touch || ![self.session isEqualToString:session] ||
                    self.sequence != sequence || !self.replayReply) return;
                if (!LCTouchSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
                    [self finishReplay:LCTapSyncResultExpired]; return;
                }
                if (![self replayWindowIsUnchanged:window]) { [self finishReplay:LCTapSyncResultGeometryChanged]; return; }
                if (self.keyboardVisible) { [self finishReplay:LCTapSyncResultKeyboardVisible]; return; }
                @try {
                    if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState)) { [self suspendForPhysicalInput]; return; }
                    [touch _setLocationInWindow:point resetPrevious:sample.phase == LCTouchSyncPhaseBegan];
                    UITouchPhase phase = sample.phase == LCTouchSyncPhaseBegan ? UITouchPhaseBegan :
                        sample.phase == LCTouchSyncPhaseMoved ? UITouchPhaseMoved :
                        sample.phase == LCTouchSyncPhaseEnded ? UITouchPhaseEnded : UITouchPhaseCancelled;
                    self.replayStream = stream;
                    if (![self sendPhase:phase timestamp:timestamp]) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
                    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
                        [self finishReplay:LCTapSyncResultAccepted];
                    } else {
                        void (^completion)(LCTapSyncResult) = self.replayReply;
                        self.replayReply = nil;
                        if (completion) completion(LCTapSyncResultAccepted);
                    }
                } @catch (NSException *exception) {
                    self.supported = NO;
                    [self finishReplay:LCTapSyncResultUnsupported];
                }
            };
            // Preserve source timing and velocity when a later packet arrives faster than the initial down.
            NSTimeInterval delay = timestamp - NSProcessInfo.processInfo.systemUptime;
            if (delay > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), deliver);
            else deliver();
        } @catch (NSException *exception) {
            self.supported = NO;
            [self finishReplay:LCTapSyncResultUnsupported];
        }
    });
}
- (BOOL)sendMultiContacts:(NSArray<LCMultiTouchContact *> *)contacts timestamp:(NSTimeInterval)timestamp {
    if (!contacts.count || !self.multiEvent) return NO;
    LCTapHIDEventRef hand = NULL;
    @try {
        uint32_t mask = 0;
        BOOL anyDown = NO;
        for (LCMultiTouchContact *contact in contacts) {
            UITouchPhase phase = contact.touch.phase;
            if (phase != UITouchPhaseStationary) mask |= 3;
            if (phase == UITouchPhaseMoved) mask |= 4;
            if (phase == UITouchPhaseCancelled) mask |= 0x80;
            if (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled) anyDown = YES;
        }
        uint64_t time = mach_absolute_time();
        hand = createHand(kCFAllocatorDefault, time, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, anyDown, anyDown, 0);
        if (!hand) return NO;
        setHIDInteger(hand, (11 << 16) + 25, 1);
        for (LCMultiTouchContact *contact in contacts) {
            UITouch *touch = contact.touch;
            BOOL down = touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
            uint32_t fingerMask = touch.phase == UITouchPhaseStationary ? 0 : 3;
            if (touch.phase == UITouchPhaseMoved) fingerMask |= 4;
            if (touch.phase == UITouchPhaseCancelled) fingerMask |= 0x80;
            CGPoint point = [touch locationInView:touch.window];
            LCTapHIDEventRef finger = createFinger(kCFAllocatorDefault, time, contact.identifier, contact.identifier,
                fingerMask, point.x, point.y, 0, 0, 0, down, down, 0);
            if (!finger) return NO;
            // Each UITouch keeps a HID event for its own identity. The UIEvent also
            // carries an aggregate hand containing all contacts, including releases.
            LCTapHIDEventRef touchHand = createHand(kCFAllocatorDefault, time, 3, 0, 0, fingerMask, 0, 0, 0, 0, 0, 0, down, down, 0);
            if (!touchHand) { CFRelease(finger); return NO; }
            @try {
                setHIDInteger(finger, (11 << 16) + 25, 1);
                setHIDInteger(touchHand, (11 << 16) + 25, 1);
                appendHID(touchHand, finger, 0);
                appendHID(hand, finger, 0);
                [touch _setHidEvent:touchHand];
                [touch setTimestamp:timestamp];
            } @finally {
                CFRelease(touchHand);
                CFRelease(finger);
            }
        }
        UIEvent *event = self.multiEvent;
        [event _clearTouches];
        [event _setHIDEvent:hand];
        [event _setTimestamp:timestamp];
        for (LCMultiTouchContact *contact in contacts) [event _addTouch:contact.touch forDelayedDelivery:NO];
        self.replaying = YES;
        for (LCMultiTouchContact *contact in contacts) if (contact.touch.phase == UITouchPhaseBegan) contact.down = YES;
        [UIApplication.sharedApplication sendEvent:event];
        for (LCMultiTouchContact *contact in contacts) {
            if (contact.touch.phase == UITouchPhaseEnded || contact.touch.phase == UITouchPhaseCancelled) contact.down = NO;
        }
        [event _clearTouches];
        return YES;
    } @catch (NSException *exception) {
        self.supported = NO;
        return NO;
    } @finally {
        self.replaying = NO;
        if (hand) CFRelease(hand);
    }
}
- (void)cancelMultiReplay {
    self.multiReplayGeneration++;
    if (!self.replayContacts.count) { self.multiEvent = nil; return; }
    NSMutableArray *down = [NSMutableArray array];
    @try {
        NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
        for (LCMultiTouchContact *contact in self.replayContacts) {
            if (!contact.down) continue;
            timestamp = MAX(timestamp, contact.touch.timestamp);
            [contact.touch setPhase:UITouchPhaseCancelled];
            [down addObject:contact];
        }
        if (down.count) [self sendMultiContacts:down timestamp:timestamp];
    } @catch (NSException *exception) { self.supported = NO; }
    self.replayContacts = nil;
    self.multiEvent = nil;
    LCMultiTouchSyncStream stream = self.replayMultiStream;
    stream.count = 0;
    self.replayMultiStream = stream;
}
- (void)replayTouchFrame:(NSDictionary *)packet session:(NSString *)session sequence:(uint64_t)sequence
                  reply:(void (^)(LCTapSyncResult))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable); return; }
        if (![self.session isEqualToString:session] || self.source) { reply(LCTapSyncResultStopped); return; }
        if (self.mode != LCTapSyncModeTwoFingers) { reply(LCTapSyncResultInvalidGesture); return; }
        if (self.suspended) { reply(self.suspensionResult); return; }
        if (self.replayReply) { reply(LCTapSyncResultBusy); return; }
        self.replayReply = reply;
        if (!self.supported) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
        if (self.keyboardVisible) { [self finishReplay:LCTapSyncResultKeyboardVisible]; return; }
        LCMultiTouchSyncFrame frame = {0};
        if (self.sequence == UINT64_MAX || sequence != self.sequence + 1 || !LCMultiTouchSyncDecode(packet, &frame) ||
            !LCMultiTouchSyncFrameIsFresh(frame, NSProcessInfo.processInfo.systemUptime)) {
            [self finishReplay:LCTapSyncResultExpired]; return;
        }
        LCMultiTouchSyncStream stream = self.replayMultiStream;
        if (!LCMultiTouchSyncAdvance(&stream, frame)) { [self finishReplay:LCTapSyncResultInvalidGesture]; return; }
        LCTapSyncResult windowResult;
        UIWindow *window = LCTapSyncGuestWindowWithResult(&windowResult);
        if (!window) { [self finishReplay:windowResult]; return; }
        if (!LCMultiTouchSyncCanMap(frame, window.bounds.size.width, window.bounds.size.height, (int)window.windowScene.interfaceOrientation)) {
            [self finishReplay:LCTapSyncResultGeometryChanged]; return;
        }
        BOOL firstFrame = self.replayMultiStream.count == 0;
        if (firstFrame) {
            self.replayTimeOffset = NSProcessInfo.processInfo.systemUptime - frame.timestamp;
            self.replayBounds = window.bounds;
            self.replayInsets = window.safeAreaInsets;
            self.replayOrientation = window.windowScene.interfaceOrientation;
        }
        self.sequence = sequence;
        NSUInteger generation = self.multiReplayGeneration;
        NSTimeInterval timestamp = frame.timestamp + self.replayTimeOffset;
        void (^deliver)(void) = ^{
            if (self.multiReplayGeneration != generation || ![self.session isEqualToString:session] ||
                self.sequence != sequence || !self.replayReply) return;
            if (!LCMultiTouchSyncFrameIsFresh(frame, NSProcessInfo.processInfo.systemUptime)) { [self finishReplay:LCTapSyncResultExpired]; return; }
            if (![self replayWindowIsUnchanged:window]) { [self finishReplay:LCTapSyncResultGeometryChanged]; return; }
            if (self.keyboardVisible) { [self finishReplay:LCTapSyncResultKeyboardVisible]; return; }
            @try {
                if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState)) {
                    [self suspendForPhysicalInput]; return;
                }
                if (firstFrame) {
                    self.multiEvent = LCTapNewEvent();
                    self.replayContacts = [NSMutableArray array];
                }
                if (!self.multiEvent) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
                for (unsigned i = 0; i < frame.count; i++) {
                    LCMultiTouchSyncContact sample = frame.contacts[i];
                    LCMultiTouchContact *contact = nil;
                    for (LCMultiTouchContact *existing in self.replayContacts) if (existing.identifier == sample.identifier) { contact = existing; break; }
                    CGPoint point = CGPointMake(CGRectGetMinX(window.bounds) + sample.x * window.bounds.size.width,
                        CGRectGetMinY(window.bounds) + sample.y * window.bounds.size.height);
                    if (sample.phase == LCMultiTouchSyncPhaseBegan) {
                        if (contact) { [self finishReplay:LCTapSyncResultInvalidGesture]; return; }
                        UITouch *touch = [self newSyntheticTouchInWindow:window point:point tapCount:(NSUInteger)sample.tapCount];
                        if (!touch) { [self finishReplay:LCTapSyncResultWindowNotReady]; return; }
                        for (LCMultiTouchContact *existing in self.replayContacts) {
                            if (existing.touch.phase != UITouchPhaseEnded && existing.touch.phase != UITouchPhaseCancelled &&
                                existing.touch.view == touch.view && [touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
                                [touch _setIsFirstTouchForView:NO]; break;
                            }
                        }
                        contact = [LCMultiTouchContact new];
                        contact.identifier = sample.identifier;
                        contact.touch = touch;
                        [self.replayContacts addObject:contact];
                    }
                    if (!contact || contact.touch.window != window) { [self finishReplay:LCTapSyncResultInvalidGesture]; return; }
                    [contact.touch _setLocationInWindow:point resetPrevious:sample.phase == LCMultiTouchSyncPhaseBegan];
                    UITouchPhase phase = sample.phase == LCMultiTouchSyncPhaseBegan ? UITouchPhaseBegan :
                        sample.phase == LCMultiTouchSyncPhaseMoved ? UITouchPhaseMoved :
                        sample.phase == LCMultiTouchSyncPhaseEnded ? UITouchPhaseEnded :
                        sample.phase == LCMultiTouchSyncPhaseCancelled ? UITouchPhaseCancelled : UITouchPhaseStationary;
                    [contact.touch setPhase:phase];
                }
                self.replayMultiStream = stream;
                if (![self sendMultiContacts:self.replayContacts timestamp:timestamp]) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
                NSIndexSet *released = [self.replayContacts indexesOfObjectsPassingTest:^BOOL(LCMultiTouchContact *contact, NSUInteger index, BOOL *stop) {
                    return !contact.down;
                }];
                [self.replayContacts removeObjectsAtIndexes:released];
                if (stream.count == 0) { [self finishReplay:LCTapSyncResultAccepted]; return; }
                void (^completion)(LCTapSyncResult) = self.replayReply;
                self.replayReply = nil;
                if (completion) completion(LCTapSyncResultAccepted);
            } @catch (NSException *exception) {
                self.supported = NO;
                [self finishReplay:LCTapSyncResultUnsupported];
            }
        };
        NSTimeInterval delay = timestamp - NSProcessInfo.processInfo.systemUptime;
        if (delay > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), deliver);
        else deliver();
    });
}
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender) { reply(LCTapSyncResultUnavailable); return; }
        if (![self.session isEqualToString:session] || self.source) { reply(LCTapSyncResultStopped); return; }
        if (self.mode != LCTapSyncModeTapsOnly) { reply(LCTapSyncResultInvalidGesture); return; }
        if (self.suspended) { reply(self.suspensionResult); return; }
        if (!self.supported) { reply(LCTapSyncResultUnsupported); return; }
        if (self.syntheticTouch) { reply(LCTapSyncResultBusy); return; }
        if (self.keyboardVisible) { reply(LCTapSyncResultKeyboardVisible); return; }
        LCTapSyncSample sample = {0};
        if (self.sequence == UINT64_MAX || sequence != self.sequence + 1 || !LCTapSyncDecode(tap, &sample) ||
            !LCTapSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
            reply(LCTapSyncResultExpired); return;
        }
        LCTapSyncResult windowResult;
        UIWindow *window = LCTapSyncGuestWindowWithResult(&windowResult);
        if (!window) { reply(windowResult); return; }
        if (!LCTapSyncCanMap(sample, window.bounds.size.width, window.bounds.size.height, (int)window.windowScene.interfaceOrientation)) {
            reply(LCTapSyncResultGeometryChanged); return;
        }
        @try {
            if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState)) {
                if (self.resumeOnSource) { [self suspendForPhysicalInput]; reply(LCTapSyncResultSuspended); }
                else reply(LCTapSyncResultPhysicalTouch);
                return;
            }
            CGPoint point = CGPointMake(CGRectGetMinX(window.bounds) + sample.x * window.bounds.size.width,
                                        CGRectGetMinY(window.bounds) + sample.y * window.bounds.size.height);
            LCTapSyncResult prepared = [self createSyntheticTouchInWindow:window point:point tapCount:(NSUInteger)sample.tapCount];
            if (prepared != LCTapSyncResultAccepted) { reply(prepared); return; }
            UITouch *touch = self.syntheticTouch;
            self.sequence = sequence;
            self.replayReply = reply;
            if (![self sendPhase:UITouchPhaseBegan]) { [self finishReplay:LCTapSyncResultUnsupported]; return; }
            // Allow guest render loops to observe the down/up phases; never block the main run loop.
            NSTimeInterval hold = MAX(0.03, MIN(sample.duration, 0.12));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.syntheticTouch != touch || ![self.session isEqualToString:session]) return;
                if (!LCTapSyncSampleIsFresh(sample, NSProcessInfo.processInfo.systemUptime)) {
                    [self finishReplay:LCTapSyncResultExpired]; return;
                }
                if (![self replayWindowIsUnchanged:window]) {
                    [self finishReplay:LCTapSyncResultGeometryChanged]; return;
                }
                if (LCTapHasRealTouches([UIApplication.sharedApplication _touchesEvent], self.inputState)) {
                    [self suspendForPhysicalInput]; return;
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
        tapSyncClient.hostEndpoint = endpoint;
        [tapSyncClient connectToHost];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [tapSyncClient.inputState resetConnectionRecovery];
            if (!tapSyncClient.connectionRetryScheduled) [tapSyncClient connectToHost];
        }];
        for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
                    tapSyncClient.keyboardVisible = NO;
                    [tapSyncClient.inputState clearPhysicalTouches];
                }
                [tapSyncClient interruptAfterCurrentEvent:LCTapSyncResultSceneInactive];
            }];
        }
        [center addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if ([note.userInfo[UIKeyboardIsLocalUserInfoKey] isEqual:@NO]) return;
            tapSyncClient.keyboardVisible = YES;
            [tapSyncClient interruptAfterCurrentEvent:LCTapSyncResultKeyboardVisible];
        }];
        for (NSString *name in @[UIKeyboardWillHideNotification, UIKeyboardDidHideNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.userInfo[UIKeyboardIsLocalUserInfoKey] isEqual:@NO]) return;
                tapSyncClient.keyboardVisible = NO;
            }];
        }
    });
}
