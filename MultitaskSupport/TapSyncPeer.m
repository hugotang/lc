#import "TapSyncPeer.h"

@interface LCTapSyncPeer () <NSXPCListenerDelegate, LCTapSyncHostProtocol>
@property(nonatomic) NSXPCListener *listener;
@property(nonatomic) NSXPCConnection *connection;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) NSUUID *performanceRequest;
@property(nonatomic) NSUUID *geometryRequest;
@property(nonatomic) NSUUID *inputDiagnosticsRequest;
@end

@implementation LCTapSyncPeer
- (instancetype)init {
    if ((self = [super init])) {
        _listener = [NSXPCListener anonymousListener];
        _listener.delegate = self;
        _endpoint = _listener.endpoint;
        [_listener resume];
    }
    return self;
}
- (void)setExpectedProcessIdentifier:(pid_t)pid {
    _expectedProcessIdentifier = pid;
    if (self.connection && self.connection.processIdentifier != pid) [self invalidate];
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    __block BOOL accept = NO;
    void (^bind)(void) = ^{
        if (self.invalidated || self.connection ||
            (self.expectedProcessIdentifier > 0 && connection.processIdentifier != self.expectedProcessIdentifier)) return;
        self.connection = connection;
        accept = YES;
    };
    if (NSThread.isMainThread) bind(); else dispatch_sync(dispatch_get_main_queue(), bind);
    if (!accept) return NO;
    connection.exportedInterface = LCTapSyncHostInterface();
    connection.exportedObject = self;
    connection.remoteObjectInterface = LCTapSyncGuestInterface();
    __weak typeof(self) weakSelf = self;
    __weak NSXPCConnection *weakConnection = connection;
    void (^disconnected)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            LCTapSyncPeer *peer = weakSelf;
            NSXPCConnection *previous = weakConnection;
            if (!peer || !previous || peer.connection != previous) return;
            peer.connection = nil;
            peer.performanceRequest = nil;
            peer.geometryRequest = nil;
            peer.inputDiagnosticsRequest = nil;
            peer->_ready = NO;
            peer->_canReplay = NO;
            [previous invalidate];
            if (peer.stateDidChange) peer.stateDidChange();
        });
    };
    connection.interruptionHandler = disconnected;
    connection.invalidationHandler = disconnected;
    [connection resume];
    return YES;
}
- (void)readyWithVersion:(NSInteger)version canReplay:(BOOL)canReplay {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sender || self.connection != sender || self.invalidated) return;
        self->_ready = version == LCTapSyncProtocolVersion;
        self->_canReplay = self.ready && canReplay;
        if (self.stateDidChange) self.stateDidChange();
    });
}
- (void)submitTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didReceiveTap) self.didReceiveTap(tap, session, sequence);
    });
}
- (void)submitTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didReceiveTouch) self.didReceiveTouch(touch, session, sequence);
    });
}
- (void)interruptSession:(NSString *)session reason:(LCTapSyncResult)reason {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didInterrupt) self.didInterrupt(session, reason);
    });
}
- (void)physicalInputChanged:(BOOL)touching began:(BOOL)began session:(NSString *)session revision:(uint64_t)revision
                    timestamp:(NSTimeInterval)timestamp returnRevision:(uint64_t)returnRevision {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didChangePhysicalInput) {
            self.didChangePhysicalInput(session, revision, touching, began, timestamp, returnRevision);
        }
    });
}
- (void)submitTouchFrame:(NSDictionary *)frame session:(NSString *)session sequence:(uint64_t)sequence {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didReceiveTouchFrame) self.didReceiveTouchFrame(frame, session, sequence);
    });
}
- (void)submitSourceReturn:(NSArray<NSDictionary *> *)packets session:(NSString *)session {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didReceiveSourceReturn) self.didReceiveSourceReturn(packets, session);
    });
}
- (void)sendWithReply:(void (^)(id<LCTapSyncGuestProtocol>, void (^)(LCTapSyncResult)))send
                reply:(void (^)(LCTapSyncResult))reply {
    if (!self.ready || !self.connection) { reply(LCTapSyncResultUnavailable); return; }
    NSXPCConnection *connection = self.connection;
    __block BOOL completed = NO;
    void (^finish)(LCTapSyncResult) = ^(LCTapSyncResult result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            reply(self.connection == connection ? result : LCTapSyncResultUnavailable);
        });
    };
    id<LCTapSyncGuestProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        finish(LCTapSyncResultUnavailable);
    }];
    send(proxy, finish);
}
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode resumeOnSource:(BOOL)resumeOnSource
         syncReturnGesture:(BOOL)syncReturnGesture
                 reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy prepareSession:session source:source mode:mode resumeOnSource:resumeOnSource syncReturnGesture:syncReturnGesture reply:finish];
    } reply:reply];
}
- (void)suspendSession:(NSString *)session reply:(void (^)(LCTapSyncResult, BOOL, uint64_t))reply {
    if (!self.ready || !self.connection) { reply(LCTapSyncResultUnavailable, NO, 0); return; }
    NSXPCConnection *connection = self.connection;
    __block BOOL completed = NO;
    void (^finish)(LCTapSyncResult, BOOL, uint64_t) = ^(LCTapSyncResult result, BOOL touching, uint64_t revision) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            reply(self.connection == connection ? result : LCTapSyncResultUnavailable, touching, revision);
        });
    };
    id<LCTapSyncGuestProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        finish(LCTapSyncResultUnavailable, NO, 0);
    }];
    [proxy suspendSession:session reply:finish];
}
- (void)stopSession:(NSString *)session {
    id<LCTapSyncGuestProtocol> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [proxy stopSession:session];
}
- (void)resumeSourceSession:(NSString *)session previousSession:(NSString *)previous inputRevision:(uint64_t)revision
                      reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy resumeSourceSession:session previousSession:previous inputRevision:revision reply:finish];
    } reply:reply];
}
- (void)discardSourceReturn:(NSString *)session beforeTime:(NSTimeInterval)time {
    id<LCTapSyncGuestProtocol> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [proxy discardSourceReturn:session beforeTime:time];
}
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy replayTap:tap session:session sequence:sequence reply:finish];
    } reply:reply];
}
- (void)replayTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence
             reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy replayTouch:touch session:session sequence:sequence reply:finish];
    } reply:reply];
}
- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    NSXPCConnection *connection = self.connection;
    self.connection = nil;
    self.performanceRequest = nil;
    self.geometryRequest = nil;
    self.inputDiagnosticsRequest = nil;
    _ready = NO;
    _canReplay = NO;
    [connection invalidate];
    [self.listener invalidate];
    if (self.stateDidChange) self.stateDidChange();
    self.stateDidChange = nil;
    self.didReceiveTap = nil;
    self.didReceiveTouch = nil;
    self.didReceiveTouchFrame = nil;
    self.didReceiveSourceReturn = nil;
    self.didInterrupt = nil;
    self.didChangePhysicalInput = nil;
}
- (void)replayTouchFrame:(NSDictionary *)frame session:(NSString *)session sequence:(uint64_t)sequence
                  reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy replayTouchFrame:frame session:session sequence:sequence reply:finish];
    } reply:reply];
}
- (void)samplePerformanceWithReply:(void (^)(NSDictionary *))reply {
    // A hung guest must not accumulate telemetry requests every second, or across
    // repeatedly opening the monitor. Input forwarding has its own independent queue.
    if (!self.ready || !self.connection || self.performanceRequest) { reply(nil); return; }
    NSUUID *request = NSUUID.UUID;
    self.performanceRequest = request;
    NSXPCConnection *connection = self.connection;
    __block BOOL completed = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *sample) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            BOOL current = self.connection == connection && self.performanceRequest == request;
            if (self.performanceRequest == request) self.performanceRequest = nil;
            reply(current && [sample isKindOfClass:NSDictionary.class] ? sample : nil);
        });
    };
    id<LCTapSyncGuestProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { finish(nil); }];
    [proxy samplePerformanceWithReply:finish];
}
- (void)readInputDiagnosticsForSession:(NSString *)session reply:(void (^)(NSDictionary *))reply {
    // The caller has one bounded deadline. Keep this gate until the actual reply
    // or disconnect, so repeated copies cannot queue work behind a stalled guest.
    if (!self.ready || !self.connection || self.inputDiagnosticsRequest) { reply(nil); return; }
    NSUUID *request = NSUUID.UUID;
    self.inputDiagnosticsRequest = request;
    NSXPCConnection *connection = self.connection;
    __block BOOL completed = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *record) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completed) return;
            completed = YES;
            BOOL current = self.connection == connection && self.inputDiagnosticsRequest == request;
            if (self.inputDiagnosticsRequest == request) self.inputDiagnosticsRequest = nil;
            reply(current && [record isKindOfClass:NSDictionary.class] ? record : nil);
        });
    };
    id<LCTapSyncGuestProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { finish(nil); }];
    [proxy readInputDiagnosticsForSession:session reply:finish];
}
- (void)readWindowGeometryWithReply:(void (^)(NSDictionary *))reply {
    // One on-demand request per guest. Timeouts discard late replies; they do
    // not queue another UI request behind an unresponsive game.
    if (!self.ready || !self.connection || self.geometryRequest) { reply(nil); return; }
    NSUUID *request = NSUUID.UUID;
    self.geometryRequest = request;
    NSXPCConnection *connection = self.connection;
    __block BOOL completed = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *geometry) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.geometryRequest == request) self.geometryRequest = nil;
            if (completed) return;
            completed = YES;
            BOOL current = self.connection == connection && !self.invalidated;
            reply(current && [geometry isKindOfClass:NSDictionary.class] ? geometry : nil);
        });
    };
    id<LCTapSyncGuestProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { finish(nil); }];
    [proxy readWindowGeometryWithReply:finish];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (completed) return;
        completed = YES;
        // Retain the in-flight gate until its response or connection closes.
        reply(nil);
    });
}
@end
