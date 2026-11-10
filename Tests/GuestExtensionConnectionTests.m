#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#include <assert.h>
#include <stdio.h>

// Exercise the production connection code with real Foundation XPC transport.
// Loading a guest executable and creating a system extension are outside this harness.
#import "../LiveContainer/Tweaks/NSExtension+GuestHooks.m"

NSString *LCPrepareGuestExtension(NSDictionary *request) {
    (void)request;
    return @"Guest executable loading is not used by the connection tests";
}

@interface LCTestExtensionPayload : NSObject <NSSecureCoding>
@property(nonatomic, copy) NSString *value;
@end

@implementation LCTestExtensionPayload
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) _value = [coder decodeObjectOfClass:NSString.class forKey:@"value"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.value forKey:@"value"]; }
@end

@protocol LCTestExtensionHostProtocol
- (void)hostPing:(NSArray *)payload reply:(void (^)(NSArray *))reply;
@end

@protocol LCTestExtensionVendorProtocol
- (void)vendorPing:(NSArray *)payload reply:(void (^)(NSArray *))reply;
@end

static NSXPCInterface *testInterface(BOOL host) {
    static NSXPCInterface *hostInterface, *vendorInterface;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hostInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTestExtensionHostProtocol)];
        vendorInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCTestExtensionVendorProtocol)];
        NSSet *classes = [NSSet setWithObjects:NSArray.class, LCTestExtensionPayload.class, nil];
        for (NSXPCInterface *interface in @[hostInterface, vendorInterface]) {
            SEL selector = interface == hostInterface ? @selector(hostPing:reply:) : @selector(vendorPing:reply:);
            [interface setClasses:classes forSelector:selector argumentIndex:0 ofReply:NO];
            [interface setClasses:classes forSelector:selector argumentIndex:0 ofReply:YES];
        }
    });
    return host ? hostInterface : vendorInterface;
}

@interface LCTestExtensionContext : NSExtensionContext <LCTestExtensionHostProtocol, LCTestExtensionVendorProtocol>
@property(nonatomic, strong) dispatch_semaphore_t vendorPingDelivered;
@end

@implementation LCTestExtensionContext
- (instancetype)init {
    if ((self = [super init])) _vendorPingDelivered = dispatch_semaphore_create(0);
    return self;
}
+ (NSXPCInterface *)_extensionAuxiliaryHostProtocol { return testInterface(YES); }
+ (NSXPCInterface *)_extensionAuxiliaryVendorProtocol { return testInterface(NO); }
- (void)hostPing:(NSArray *)payload reply:(void (^)(NSArray *))reply { reply(payload); }
- (void)vendorPing:(NSArray *)payload reply:(void (^)(NSArray *))reply {
    dispatch_semaphore_signal(self.vendorPingDelivered);
    reply(payload);
}
@end

// Delay only the control response. Listener acceptance, message encoding,
// endpoint transfer, auxiliary connections and ping replies remain real XPC.
@interface LCTestDelayedExtensionHost : LCGuestExtensionContextState
@property(nonatomic, strong) dispatch_semaphore_t receivedHandshake;
@property(nonatomic, strong) NSXPCListenerEndpoint *pendingEndpoint;
@property(nonatomic, copy) void (^pendingReply)(NSXPCListenerEndpoint *);
- (void)releaseHandshake;
@end

@implementation LCTestDelayedExtensionHost
- (instancetype)init {
    if ((self = [super init])) _receivedHandshake = dispatch_semaphore_create(0);
    return self;
}
- (void)lcConnectWithEndpoint:(NSXPCListenerEndpoint *)endpoint completion:(void (^)(NSXPCListenerEndpoint *))completion {
    @synchronized (self) {
        assert(!self.pendingReply);
        self.pendingEndpoint = endpoint;
        self.pendingReply = completion;
    }
    dispatch_semaphore_signal(self.receivedHandshake);
}
- (void)releaseHandshake {
    NSXPCListenerEndpoint *endpoint;
    void (^reply)(NSXPCListenerEndpoint *);
    @synchronized (self) {
        endpoint = self.pendingEndpoint;
        reply = self.pendingReply;
        self.pendingEndpoint = nil;
        self.pendingReply = nil;
    }
    assert(endpoint && reply);
    [super lcConnectWithEndpoint:endpoint completion:reply];
}
@end

static dispatch_time_t deadline(NSTimeInterval seconds) {
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
}

static void waitFor(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore, deadline(5)) == 0);
}

@interface LCTestObservedVendorState : LCGuestExtensionContextState
@property(nonatomic, strong) dispatch_semaphore_t acceptedAuxiliaryConnection;
@end

@implementation LCTestObservedVendorState
- (instancetype)init {
    if ((self = [super init])) _acceptedAuxiliaryConnection = dispatch_semaphore_create(0);
    return self;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    BOOL accepted = [super listener:listener shouldAcceptNewConnection:connection];
    if (accepted && self.vendorListener && self.listener == listener) {
        dispatch_semaphore_signal(self.acceptedAuxiliaryConnection);
    }
    return accepted;
}
@end

@interface LCTestEarlyRPCGuestContext : LCTestExtensionContext
@end

@implementation LCTestEarlyRPCGuestContext
- (void)vendorPing:(NSArray *)payload reply:(void (^)(NSArray *))reply {
    // This models a vendor RPC that immediately calls its host in response.
    NSXPCConnection *connection = [(LCGuestExtensionContext *)self _auxiliaryConnection];
    assert(connection);
    id<LCTestExtensionHostProtocol> host = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        (void)error;
        assert(!"The early vendor RPC could not call its host");
    }];
    [host hostPing:payload reply:reply];
    dispatch_semaphore_signal(self.vendorPingDelivered);
}
@end

@interface LCTestEarlyRPCHostState : LCGuestExtensionContextState
@property(nonatomic, strong) LCTestObservedVendorState *vendor;
@property(nonatomic, strong) dispatch_semaphore_t receivedPingReply;
@end

@implementation LCTestEarlyRPCHostState
- (instancetype)init {
    if ((self = [super init])) _receivedPingReply = dispatch_semaphore_create(0);
    return self;
}
- (void)lcConnectWithEndpoint:(NSXPCListenerEndpoint *)endpoint completion:(void (^)(NSXPCListenerEndpoint *))completion {
    [super lcConnectWithEndpoint:endpoint completion:^(NSXPCListenerEndpoint *hostEndpoint) {
        assert(hostEndpoint && self.connection);
        id<LCTestExtensionVendorProtocol> vendor = [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            (void)error;
            assert(!"The host's early auxiliary RPC failed");
        }];
        [vendor vendorPing:@[] reply:^(NSArray *items) {
            assert(items.count == 0);
            dispatch_semaphore_signal(self.receivedPingReply);
        }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            waitFor(self.vendor.acceptedAuxiliaryConnection);
            LCTestExtensionContext *context = (id)self.vendor.context;
            // Acceptance happened; application RPC delivery must still be
            // suspended until the vendor receives its outgoing endpoint.
            assert(dispatch_semaphore_wait(context.vendorPingDelivered, deadline(0.05)) != 0);
            completion(hostEndpoint);
        });
    }];
}
@end

static LCGuestExtensionContextState *contextState(Class stateClass, BOOL host) {
    LCGuestExtensionContextState *state = [stateClass new];
    NSExtensionContext *context = LCCreateGuestContext(LCTestExtensionContext.class, state);
    assert(context && [context isKindOfClass:LCTestExtensionContext.class]);
    if (host) {
        state.usesHandshake = YES;
        state.listener = NSXPCListener.anonymousListener;
        state.listener.delegate = state;
        [state.listener resume];
    }
    return state;
}

static NSDictionary *handshakeRequest(LCGuestExtensionContextState *host) {
    return @{@"auxiliaryEndpoint": host.listener.endpoint, @"auxiliaryHandshake": @YES};
}

static void assertInvalidated(LCGuestExtensionContextState *state) {
    @synchronized (state) {
        assert(state.invalidated);
        assert(!state.listener && !state.auxiliaryListener && !state.controlConnection);
        assert(!state.connection && !state.incomingConnection && !state.context);
    }
}

static void ping(LCGuestExtensionContextState *sender, BOOL fromHost) {
    NSXPCConnection *connection = [(LCGuestExtensionContext *)sender.context _auxiliaryConnection];
    assert(connection);
    assert(connection.remoteObjectInterface == testInterface(!fromHost));
    assert(connection.exportedInterface == testInterface(fromHost));
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block NSError *error;
    __block NSArray *returned;
    LCTestExtensionPayload *payload = [LCTestExtensionPayload new];
    payload.value = fromHost ? @"host initiated" : @"vendor initiated";
    id proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *failure) {
        error = failure;
        dispatch_semaphore_signal(received);
    }];
    void (^reply)(NSArray *) = ^(NSArray *items) {
        returned = items;
        dispatch_semaphore_signal(received);
    };
    if (fromHost) [(id<LCTestExtensionVendorProtocol>)proxy vendorPing:@[payload] reply:reply];
    else [(id<LCTestExtensionHostProtocol>)proxy hostPing:@[payload] reply:reply];
    waitFor(received);
    assert(!error && returned.count == 1);
    assert([returned[0] isKindOfClass:LCTestExtensionPayload.class]);
    assert([((LCTestExtensionPayload *)returned[0]).value isEqual:payload.value]);
}

static void testEitherSideCanInitiate(BOOL hostFirst) {
    LCGuestExtensionContextState *host = contextState(LCGuestExtensionContextState.class, YES);
    LCGuestExtensionContextState *vendor = contextState(LCGuestExtensionContextState.class, NO);
    // Deliberately block the main thread: Foundation must service the handshake
    // and both pings without a main-queue dispatch or run-loop pumping.
    assert(NSThread.isMainThread);
    NSError *error = LCConnectGuestContextWithTimeout(vendor, vendor.context.class, handshakeRequest(host), 5);
    assert(!error && host.connection && vendor.connection);
    ping(hostFirst ? host : vendor, hostFirst);
    ping(hostFirst ? vendor : host, !hostFirst);
    assert(host.incomingConnection && vendor.incomingConnection);
    assert(host.connection != host.incomingConnection && vendor.connection != vendor.incomingConnection);
    [vendor invalidate];
    [host invalidate];
    assertInvalidated(vendor);
    assertInvalidated(host);
}

static void testDelayedHandshakeBlocksReturn(void) {
    LCTestDelayedExtensionHost *host = (id)contextState(LCTestDelayedExtensionHost.class, YES);
    LCGuestExtensionContextState *vendor = contextState(LCGuestExtensionContextState.class, NO);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_semaphore_t released = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        waitFor(host.receivedHandshake);
        assert(dispatch_semaphore_wait(returned, deadline(0.05)) != 0);
        @synchronized (vendor) { assert(!vendor.connection); }
        [host releaseHandshake];
        dispatch_semaphore_signal(released);
    });
    NSError *error = LCConnectGuestContextWithTimeout(vendor, vendor.context.class, handshakeRequest(host), 5);
    dispatch_semaphore_signal(returned);
    waitFor(released);
    assert(!error && vendor.connection);
    ping(vendor, NO);
    [vendor invalidate];
    [host invalidate];
}

static void testEarlyHostCallWaitsForVendorOutgoingConnection(void) {
    LCTestEarlyRPCHostState *host = (id)contextState(LCTestEarlyRPCHostState.class, YES);
    LCTestObservedVendorState *vendor = [LCTestObservedVendorState new];
    assert(LCCreateGuestContext(LCTestEarlyRPCGuestContext.class, vendor));
    host.vendor = vendor;
    NSError *error = LCConnectGuestContextWithTimeout(vendor, vendor.context.class, handshakeRequest(host), 5);
    assert(!error);
    waitFor(host.receivedPingReply);
    [vendor invalidate];
    [host invalidate];
    host.vendor = nil;
}

static void testHostInvalidationDuringHandshake(void) {
    LCTestDelayedExtensionHost *host = (id)contextState(LCTestDelayedExtensionHost.class, YES);
    LCGuestExtensionContextState *vendor = contextState(LCGuestExtensionContextState.class, NO);
    NSDictionary *request = handshakeRequest(host);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    __block NSError *error;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        error = LCConnectGuestContextWithTimeout(vendor, vendor.context.class, request, 5);
        dispatch_semaphore_signal(returned);
    });
    waitFor(host.receivedHandshake);
    [host invalidate];
    waitFor(returned);
    assert(error);
    assertInvalidated(vendor);
    // A deferred control callback after cancellation cannot recreate either side.
    [host releaseHandshake];
    assertInvalidated(host);
    assertInvalidated(vendor);
}

static void testTimeoutRejectsLateHandshake(void) {
    LCTestDelayedExtensionHost *host = (id)contextState(LCTestDelayedExtensionHost.class, YES);
    LCGuestExtensionContextState *vendor = contextState(LCGuestExtensionContextState.class, NO);
    NSDictionary *request = handshakeRequest(host);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    __block NSError *error;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        error = LCConnectGuestContextWithTimeout(vendor, vendor.context.class, request, 1);
        dispatch_semaphore_signal(returned);
    });
    waitFor(host.receivedHandshake);
    waitFor(returned);
    assert(error && [error.localizedDescription containsString:@"Timed out"]);
    assertInvalidated(vendor);
    [host releaseHandshake];
    assertInvalidated(vendor);
    [host invalidate];
}

static void testNoEndpointNeedsNoConnection(void) {
    LCGuestExtensionContextState *vendor = contextState(LCGuestExtensionContextState.class, NO);
    NSExtensionContext *context = vendor.context;
    assert(!LCConnectGuestContextWithTimeout(vendor, context.class, @{}, 0));
    assert(vendor.context == context && !vendor.invalidated);
    assert(!vendor.connection && !vendor.listener && !vendor.controlConnection);
    [vendor invalidate];
}

int main(void) {
    @autoreleasepool {
        testNoEndpointNeedsNoConnection();
        testEitherSideCanInitiate(YES);
        testEitherSideCanInitiate(NO);
        testDelayedHandshakeBlocksReturn();
        testEarlyHostCallWaitsForVendorOutgoingConnection();
        testHostInvalidationDuringHandshake();
        testTimeoutRejectsLateHandshake();
    }
    puts("Guest extension connection tests passed (real NSXPC, custom classes, both initiation directions, delayed readiness and cancellation)");
    return 0;
}
