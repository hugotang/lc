#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <xpc/xpc.h>
#import "../LiveContainer/LivePlugInSupport/PrivateXPC.h"
#import "../LiveContainer/LivePlugInSupport/LivePlugInServer.h"
#import "../LiveContainer/LCSharedUtils.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Only the system rendezvous is faked. Configuration requests and replies use
// a real anonymous libxpc listener, including the kernel-provided peer PID.
@interface LCTestClientScenario : NSObject
@property(nonatomic, strong) xpc_object_t properties;
@property(nonatomic, copy) NSString *appGroup;
@property(nonatomic) kern_return_t bootstrapResult;
@property(nonatomic) mach_port_t bootstrapPort;
@property(nonatomic) BOOL pipeAvailable;
@property(nonatomic) int routineResult;
@property(nonatomic, strong) xpc_object_t pipeReply;
@property(nonatomic, strong) dispatch_semaphore_t pipeGate;
@property(nonatomic, strong) dispatch_semaphore_t pipeEntered;
@property(nonatomic, strong) dispatch_semaphore_t pipeReturned;
@property(nonatomic) int64_t timeoutNanoseconds;
@property(nonatomic) NSUInteger bootstrapCalls;
@property(nonatomic) NSUInteger deallocatedPorts;
@property(nonatomic) NSUInteger pipeCreations;
@property(nonatomic) NSUInteger connectionCreations;
@property(nonatomic) NSUInteger deadlineCalls;
@property(nonatomic) int64_t requestedTimeoutNanoseconds;
@end
@implementation LCTestClientScenario
@end

static LCTestClientScenario *scenario;

@interface LCTestClientSharedUtils : NSObject
+ (NSString *)appGroupID;
@end
@implementation LCTestClientSharedUtils
+ (NSString *)appGroupID { return scenario.appGroup; }
@end

static xpc_object_t LCTestClientProperties(pid_t pid) XPC_RETURNS_RETAINED;
static kern_return_t LCTestClientLookup(mach_port_t bootstrap, const char *name, mach_port_t *port);
static kern_return_t LCTestClientDeallocate(ipc_space_t task, mach_port_name_t port);
static xpc_object_t LCTestClientPipe(mach_port_t port, uint32_t flags) XPC_RETURNS_RETAINED;
static int LCTestClientPipeRoutine(xpc_object_t pipe, xpc_object_t request, xpc_object_t __strong *reply);
static void LCTestClientAudit(xpc_object_t reply, audit_token_t *audit);
static xpc_connection_t LCTestClientConnection(xpc_endpoint_t endpoint) XPC_RETURNS_RETAINED;
static dispatch_time_t LCTestClientDeadline(dispatch_time_t when, int64_t delta);

#define LCSharedUtils LCTestClientSharedUtils
#define launch_copy_extension_properties_for_pid LCTestClientProperties
#define bootstrap_look_up LCTestClientLookup
#define mach_port_deallocate LCTestClientDeallocate
#define xpc_pipe_create_from_port LCTestClientPipe
#define xpc_pipe_routine LCTestClientPipeRoutine
#define xpc_dictionary_get_audit_token LCTestClientAudit
#define xpc_connection_create_from_endpoint LCTestClientConnection
#define dispatch_time LCTestClientDeadline
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#import "../LiveProcess/LivePlugIn.m"
#pragma clang diagnostic pop
#undef dispatch_time
#undef xpc_connection_create_from_endpoint
#undef xpc_dictionary_get_audit_token
#undef xpc_pipe_routine
#undef xpc_pipe_create_from_port
#undef mach_port_deallocate
#undef bootstrap_look_up
#undef launch_copy_extension_properties_for_pid
#undef LCSharedUtils

NSString *LCRunGuestExtension(NSDictionary *request, int argc, char *argv[], char *envp[], char *apple[]) {
    (void)request; (void)argc; (void)argv; (void)envp; (void)apple;
    return @"Guest executable loading is outside the client transport tests";
}

static xpc_object_t LCTestClientProperties(pid_t pid) {
    assert(pid == getpid());
    return scenario.properties;
}

static kern_return_t LCTestClientLookup(mach_port_t bootstrap, const char *name, mach_port_t *port) {
    (void)bootstrap;
    scenario.bootstrapCalls++;
    pid_t host = (pid_t)xpc_dictionary_get_int64(scenario.properties, "XPCExtensionHostPID");
    assert(strcmp(name, LCLivePlugInServiceName(scenario.appGroup, host).UTF8String) == 0);
    *port = scenario.bootstrapPort;
    return scenario.bootstrapResult;
}

static kern_return_t LCTestClientDeallocate(ipc_space_t task, mach_port_name_t port) {
    assert(task == mach_task_self() && port == scenario.bootstrapPort);
    scenario.deallocatedPorts++;
    return KERN_SUCCESS;
}

static xpc_object_t LCTestClientPipe(mach_port_t port, uint32_t flags) {
    assert(port == scenario.bootstrapPort && flags == 0);
    scenario.pipeCreations++;
    return scenario.pipeAvailable ? xpc_dictionary_create(NULL, NULL, 0) : nil;
}

static int LCTestClientPipeRoutine(xpc_object_t pipe, xpc_object_t request, xpc_object_t __strong *reply) {
    (void)pipe;
    LCTestClientScenario *current = scenario;
    assert(xpc_dictionary_get_int64(request, "cmd") == LCLivePlugInCommandConnect);
    dispatch_semaphore_signal(current.pipeEntered);
    if (current.pipeGate) dispatch_semaphore_wait(current.pipeGate, DISPATCH_TIME_FOREVER);
    *reply = current.pipeReply;
    int result = current.routineResult;
    dispatch_semaphore_signal(current.pipeReturned);
    return result;
}

static void LCTestClientAudit(xpc_object_t reply, audit_token_t *audit) {
    memset(audit, 0, sizeof(*audit));
    audit->val[5] = (uint32_t)xpc_dictionary_get_int64(reply, "test-host-pid");
}

static xpc_connection_t LCTestClientConnection(xpc_endpoint_t endpoint) {
    scenario.connectionCreations++;
    return xpc_connection_create_from_endpoint(endpoint);
}

static dispatch_time_t LCTestClientDeadline(dispatch_time_t when, int64_t delta) {
    scenario.deadlineCalls++;
    scenario.requestedTimeoutNanoseconds = delta;
    // Keep the production deadline calculation exercised while making timeout
    // cases finish quickly. Test harness waits below use unmodified dispatch.
    return dispatch_time(when, MIN(delta, scenario.timeoutNanoseconds));
}

typedef NS_ENUM(NSUInteger, LCTestClientReplyMode) {
    LCTestClientReplyValid,
    LCTestClientReplyMissingPayload,
    LCTestClientReplyDeferred,
};

@interface LCTestClientServer : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) xpc_connection_t listener;
@property(nonatomic, strong) xpc_connection_t peer;
@property(nonatomic, strong) xpc_object_t request;
@property(nonatomic, strong) NSData *payload;
@property(nonatomic) LCTestClientReplyMode mode;
@property(nonatomic) NSUInteger requests;
- (instancetype)initWithConfiguration:(NSDictionary *)configuration mode:(LCTestClientReplyMode)mode;
- (NSUInteger)requestCount;
- (void)sendDeferredReply;
- (void)stop;
@end

@implementation LCTestClientServer
- (instancetype)initWithConfiguration:(NSDictionary *)configuration mode:(LCTestClientReplyMode)mode {
    if ((self = [super init])) {
        _mode = mode;
        _queue = dispatch_queue_create("LiveContainer.Tests.GuestPlugInClient", DISPATCH_QUEUE_SERIAL);
        NSError *error = nil;
        _payload = [NSKeyedArchiver archivedDataWithRootObject:configuration requiringSecureCoding:NO error:&error];
        assert(_payload && !error);
        _listener = xpc_connection_create(NULL, _queue);
        assert(_listener);
        __weak typeof(self) weakSelf = self;
        xpc_connection_set_event_handler(_listener, ^(xpc_object_t object) {
            LCTestClientServer *server = weakSelf;
            if (!server || xpc_get_type(object) != XPC_TYPE_CONNECTION) return;
            xpc_connection_t peer = object;
            server.peer = peer;
            xpc_connection_set_target_queue(peer, server.queue);
            __weak xpc_connection_t weakPeer = peer;
            xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
                LCTestClientServer *active = weakSelf;
                xpc_connection_t connection = weakPeer;
                if (!active || !connection || xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
                assert(xpc_dictionary_get_int64(request, "cmd") == LCLivePlugInCommandLaunchConfiguration);
                active.requests++;
                if (active.mode == LCTestClientReplyDeferred) {
                    active.request = request;
                    return;
                }
                xpc_object_t reply = xpc_dictionary_create_reply(request);
                assert(reply);
                if (active.mode == LCTestClientReplyValid) {
                    xpc_dictionary_set_data(reply, "payload", active.payload.bytes, active.payload.length);
                }
                xpc_connection_send_message(connection, reply);
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(_listener);
    }
    return self;
}
- (NSUInteger)requestCount {
    __block NSUInteger count;
    dispatch_sync(self.queue, ^{ count = self.requests; });
    return count;
}
- (void)sendDeferredReply {
    dispatch_sync(self.queue, ^{
        assert(self.request && self.peer);
        xpc_object_t reply = xpc_dictionary_create_reply(self.request);
        assert(reply);
        xpc_dictionary_set_data(reply, "payload", self.payload.bytes, self.payload.length);
        xpc_connection_send_message(self.peer, reply);
        self.request = nil;
    });
}
- (void)stop {
    dispatch_sync(self.queue, ^{
        if (self.peer) xpc_connection_cancel(self.peer);
        if (self.listener) xpc_connection_cancel(self.listener);
        self.peer = nil;
        self.listener = nil;
        self.request = nil;
    });
}
@end

static void resetScenario(void) {
    if (hostConnection) xpc_connection_cancel(hostConnection);
    hostConnection = nil;
    retrievedAppInfo = nil;
    scenario = [LCTestClientScenario new];
    scenario.properties = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(scenario.properties, "XPCExtensionHostPID", getpid());
    scenario.appGroup = @"group.LiveContainer.client-tests";
    scenario.bootstrapResult = KERN_SUCCESS;
    scenario.bootstrapPort = 42; // Mock port: the matching deallocator is intercepted.
    scenario.pipeAvailable = YES;
    scenario.pipeEntered = dispatch_semaphore_create(0);
    scenario.pipeReturned = dispatch_semaphore_create(0);
    scenario.timeoutNanoseconds = 3 * NSEC_PER_SEC;
}

static void waitForSemaphore(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
}

static void assertError(NSString *fragment) {
    NSString *error = [LivePlugInHandler retrieveLaunchConfiguration];
    assert(error && [error containsString:fragment]);
    assert(!hostConnection && !LivePlugInHandler.retrievedAppInfo);
}

static NSDictionary *configuration(void) {
    return @{@"bundlePath": @"/test/Guest.app/PlugIns/Helper.appex",
             @"containerPath": @"/test/Data/Extensions/helper",
             @"bookmarks": @[[NSData dataWithBytes:"bookmark" length:8]],
             @"guestAppInfo": @{@"helperProcessesSupport": @YES},
             @"created": [NSDate dateWithTimeIntervalSince1970:1234]};
}

static void useServer(LCTestClientServer *server, pid_t auditPID) {
    scenario.pipeReply = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(scenario.pipeReply, "test-host-pid", auditPID);
    xpc_dictionary_set_value(scenario.pipeReply, "listener", xpc_endpoint_create(server.listener));
}

static void testMissingHostMetadata(void) {
    resetScenario();
    scenario.properties = nil;
    assertError(@"host properties");
    assert(scenario.bootstrapCalls == 0);

    resetScenario();
    scenario.properties = xpc_string_create("invalid properties");
    assertError(@"host properties");
    assert(scenario.bootstrapCalls == 0);

    resetScenario();
    xpc_dictionary_set_int64(scenario.properties, "XPCExtensionHostPID", 0);
    assertError(@"host or app group");
    assert(scenario.bootstrapCalls == 0);

    resetScenario();
    scenario.appGroup = nil;
    assertError(@"host or app group");
    assert(scenario.bootstrapCalls == 0);
}

static void testBootstrapAndPipeFailures(void) {
    resetScenario();
    scenario.bootstrapResult = KERN_FAILURE;
    scenario.bootstrapPort = MACH_PORT_NULL;
    assertError(@"bootstrap_look_up failed");
    assert(scenario.pipeCreations == 0 && scenario.deallocatedPorts == 0);

    resetScenario();
    scenario.bootstrapResult = KERN_FAILURE;
    assertError(@"bootstrap_look_up failed");
    assert(scenario.pipeCreations == 0 && scenario.deallocatedPorts == 1);

    resetScenario();
    scenario.bootstrapPort = MACH_PORT_NULL;
    assertError(@"bootstrap_look_up failed");
    assert(scenario.pipeCreations == 0);

    resetScenario();
    scenario.pipeAvailable = NO;
    assertError(@"bootstrap pipe");
    assert(scenario.pipeCreations == 1 && scenario.deallocatedPorts == 1);

    resetScenario();
    scenario.routineResult = EIO;
    assertError(@"bootstrap service");
    assert(scenario.connectionCreations == 0);

    resetScenario();
    scenario.pipeReply = xpc_string_create("invalid reply");
    assertError(@"bootstrap service");
    assert(scenario.connectionCreations == 0);
}

static void testHostAuthentication(void) {
    resetScenario();
    LCTestClientServer *server = [[LCTestClientServer alloc] initWithConfiguration:configuration() mode:LCTestClientReplyValid];
    useServer(server, getpid() + 1);
    assertError(@"bootstrap service");
    assert(scenario.connectionCreations == 0 && server.requestCount == 0);
    [server stop];

    // A correctly attested bootstrap reply cannot authorize a different PID
    // on the final connection. The real server still runs in this process.
    resetScenario();
    xpc_dictionary_set_int64(scenario.properties, "XPCExtensionHostPID", getpid() + 1);
    server = [[LCTestClientServer alloc] initWithConfiguration:configuration() mode:LCTestClientReplyValid];
    useServer(server, getpid() + 1);
    assertError(@"configuration failed");
    assert(scenario.connectionCreations == 1 && server.requestCount == 1);
    [server stop];
}

static void testConfigurationDelivery(void) {
    resetScenario();
    NSDictionary *expected = configuration();
    LCTestClientServer *server = [[LCTestClientServer alloc] initWithConfiguration:expected mode:LCTestClientReplyValid];
    useServer(server, getpid());
    assert([LivePlugInHandler retrieveLaunchConfiguration] == nil);
    assert([LivePlugInHandler.retrievedAppInfo isEqualToDictionary:expected]);
    assert(hostConnection && scenario.connectionCreations == 1 && server.requestCount == 1);
    assert(scenario.deadlineCalls == 1);
    assert(scenario.requestedTimeoutNanoseconds == (int64_t)(LCLivePlugInLaunchTimeout * NSEC_PER_SEC));
    [server stop];

    resetScenario();
    server = [[LCTestClientServer alloc] initWithConfiguration:expected mode:LCTestClientReplyMissingPayload];
    useServer(server, getpid());
    assertError(@"configuration failed");
    assert(server.requestCount == 1);
    [server stop];
}

static void testBoundedBootstrapWait(void) {
    resetScenario();
    LCTestClientServer *server = [[LCTestClientServer alloc] initWithConfiguration:configuration() mode:LCTestClientReplyValid];
    useServer(server, getpid());
    scenario.timeoutNanoseconds = NSEC_PER_SEC / 10;
    scenario.pipeGate = dispatch_semaphore_create(0);
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    assertError(@"bootstrap service");
    assert(NSProcessInfo.processInfo.systemUptime - start < 2.0);
    assert(scenario.deadlineCalls == 1 && scenario.connectionCreations == 0);
    waitForSemaphore(scenario.pipeEntered);
    // Release the late response instead of leaving a blocked test worker.
    dispatch_semaphore_signal(scenario.pipeGate);
    waitForSemaphore(scenario.pipeReturned);
    assert(!hostConnection && !LivePlugInHandler.retrievedAppInfo && server.requestCount == 0);
    [server stop];
}

static void testBoundedConfigurationWait(void) {
    resetScenario();
    LCTestClientServer *server = [[LCTestClientServer alloc] initWithConfiguration:configuration() mode:LCTestClientReplyDeferred];
    useServer(server, getpid());
    scenario.timeoutNanoseconds = NSEC_PER_SEC;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    assertError(@"Timed out retrieving");
    assert(NSProcessInfo.processInfo.systemUptime - start < 3.0);
    assert(scenario.deadlineCalls == 1 && server.requestCount == 1);
    [server sendDeferredReply];
    assert(!hostConnection && !LivePlugInHandler.retrievedAppInfo);
    [server stop];
}

int main(void) {
    @autoreleasepool {
        testMissingHostMetadata();
        testBootstrapAndPipeFailures();
        testHostAuthentication();
        testConfigurationDelivery();
        testBoundedBootstrapWait();
        testBoundedConfigurationWait();
        if (hostConnection) xpc_connection_cancel(hostConnection);
        hostConnection = nil;
    }
    puts("Guest PlugIn client validation, authenticated transport and timeout tests passed");
    return 0;
}
