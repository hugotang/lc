#import "TapSyncPeer.h"

@interface LCTapSyncPeer () <NSXPCListenerDelegate, LCTapSyncHostProtocol>
@property(nonatomic) NSXPCListener *listener;
@property(nonatomic) NSXPCConnection *connection;
@property(nonatomic) BOOL invalidated;
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
        self->_ready = version == 1;
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
- (void)interruptSession:(NSString *)session reason:(LCTapSyncResult)reason {
    NSXPCConnection *sender = NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sender && self.connection == sender && self.ready && self.didInterrupt) self.didInterrupt(session, reason);
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
- (void)prepareSession:(NSString *)session source:(BOOL)source reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy prepareSession:session source:source reply:finish];
    } reply:reply];
}
- (void)stopSession:(NSString *)session {
    id<LCTapSyncGuestProtocol> proxy = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [proxy stopSession:session];
}
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply {
    [self sendWithReply:^(id<LCTapSyncGuestProtocol> proxy, void (^finish)(LCTapSyncResult)) {
        [proxy replayTap:tap session:session sequence:sequence reply:finish];
    } reply:reply];
}
- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    NSXPCConnection *connection = self.connection;
    self.connection = nil;
    _ready = NO;
    _canReplay = NO;
    [connection invalidate];
    [self.listener invalidate];
    if (self.stateDidChange) self.stateDidChange();
    self.stateDidChange = nil;
    self.didReceiveTap = nil;
    self.didInterrupt = nil;
}
@end
