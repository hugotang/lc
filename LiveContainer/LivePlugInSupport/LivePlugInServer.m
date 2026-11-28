#import "LivePlugInServer.h"
#import "PrivateXPC.h"
#import "LCSharedUtils.h"
#import "utils.h"

@interface LCLivePlugIn ()
@property(nonatomic, strong) NSUUID *identifier;
@property(nonatomic, strong) NSData *configurationData;
@property(nonatomic, strong) xpc_connection_t connection;
@property(nonatomic, strong) xpc_object_t configurationRequest;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSError *terminalError;
- (void)deliverConfiguration;
- (void)finishWithError:(NSError *)error;
+ (LCLivePlugIn *)processWithPID:(pid_t)pid;
@end

// PluginKit and XPC callbacks can arrive on different queues. Keep launch
// registration, PID publication, peer matching and terminal cleanup together.
static dispatch_queue_t serverQueue;
static char serverQueueKey;
static NSMutableDictionary<NSUUID *, LCLivePlugIn *> *launches;
static NSMutableDictionary<NSNumber *, xpc_connection_t> *pendingConnections;
static NSMutableDictionary<NSNumber *, xpc_object_t> *pendingRequests;
static xpc_connection_t listener;
static dispatch_source_t bootstrapSource;
static NSError *listenerError;
static BOOL serverStarted;

static void LCInitializePlugInState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        serverQueue = dispatch_queue_create("com.kdt.livecontainer.LivePlugIn.xpc.handling", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(serverQueue, &serverQueueKey, &serverQueueKey, NULL);
        launches = [NSMutableDictionary dictionary];
        pendingConnections = [NSMutableDictionary dictionary];
        pendingRequests = [NSMutableDictionary dictionary];
    });
}

static void LCWithPlugInState(dispatch_block_t block) {
    LCInitializePlugInState();
    if (dispatch_get_specific(&serverQueueKey)) block();
    else dispatch_sync(serverQueue, block);
}

static NSError *LCProcessError(NSString *description) {
    return [NSError errorWithDomain:@"LivePlugIn" code:2 userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void LCDiscardPendingPeer(NSNumber *pid, xpc_connection_t peer) {
    if (pendingConnections[pid] != peer) return;
    [pendingConnections removeObjectForKey:pid];
    [pendingRequests removeObjectForKey:pid];
}

static void LCExpirePlugIn(LCLivePlugIn *process) {
    if (launches[process.identifier] == process && !process.finished && process.configurationData) {
        [process finishWithError:LCProcessError(@"Timed out preparing the guest helper")];
    }
}

static void LCHandlePlugInPeerEvent(xpc_connection_t peer, xpc_object_t event) {
    NSNumber *pid = @(LCXPCConnectionGetPID(peer));
    LCLivePlugIn *process = [LCLivePlugIn processWithPID:pid.intValue];
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
        LCDiscardPendingPeer(pid, peer);
        if (process.connection == peer) [process finishWithError:nil];
        return;
    }
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    int64_t command = xpc_dictionary_get_int64(event, "cmd");
    if (command == LCLivePlugInCommandLaunchConfiguration) {
        if (pid.intValue <= 0 || process.connection || pendingConnections[pid]) {
            xpc_connection_cancel(peer);
            return;
        }
        pendingConnections[pid] = peer;
        pendingRequests[pid] = event;
        [LCLivePlugIn resolvePendingRequests];
    } else if (command == LCLivePlugInCommandError && process.connection == peer) {
        const char *message = xpc_dictionary_get_string(event, "error");
        xpc_object_t reply = xpc_dictionary_create_reply(event);
        if (reply) xpc_connection_send_message(peer, reply);
        [process finishWithError:LCProcessError(message ? @(message) : @"LivePlugIn failed to launch")];
    } else {
        xpc_connection_cancel(peer);
    }
}

static void LCAcceptPlugInPeer(xpc_connection_t peer) {
    xpc_connection_set_target_queue(peer, serverQueue);
    __weak xpc_connection_t weakPeer = peer;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        xpc_connection_t peer = weakPeer;
        if (peer) LCHandlePlugInPeerEvent(peer, event);
    });
    xpc_connection_resume(peer);
    // Bound unauthenticated peers, including children whose PluginKit ready
    // callback never supplies the PID.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LCLivePlugInLaunchTimeout * NSEC_PER_SEC), serverQueue, ^{
        NSNumber *pid = @(LCXPCConnectionGetPID(peer));
        if ([LCLivePlugIn processWithPID:pid.intValue].connection == peer) return;
        LCDiscardPendingPeer(pid, peer);
        xpc_connection_cancel(peer);
    });
}

@implementation LCLivePlugIn {
    pid_t _pid;
}

+ (LCLivePlugIn *)processWithPID:(pid_t)pid {
    if (pid <= 0) return nil;
    for (LCLivePlugIn *process in launches.allValues) {
        if (process->_pid == pid) return process;
    }
    return nil;
}

- (pid_t)pid {
    __block pid_t result;
    LCWithPlugInState(^{ result = self->_pid; });
    return result;
}

- (BOOL)bindToPID:(pid_t)pid error:(NSError **)error {
    __block NSError *failure;
    LCWithPlugInState(^{
        if (self.finished) {
            failure = self.terminalError ?: LCProcessError(@"The guest helper launch was cancelled");
            return;
        }
        LCLivePlugIn *existing = [LCLivePlugIn processWithPID:pid];
        if (pid <= 0 || (existing && existing != self) || (self->_pid && self->_pid != pid)) {
            failure = LCProcessError(@"PluginKit returned an invalid or duplicate helper process");
            [self finishWithError:failure];
            return;
        }
        self->_pid = pid;
        [LCLivePlugIn resolvePendingRequests];
        if (self.finished) failure = self.terminalError ?: LCProcessError(@"The guest helper launch was cancelled");
    });
    if (error) *error = failure;
    return failure == nil;
}

+ (void)resolvePendingRequests {
    LCWithPlugInState(^{
        for (NSNumber *pid in pendingRequests.allKeys) {
            LCLivePlugIn *process = [self processWithPID:pid.intValue];
            if (!process || process.connection) continue;
            xpc_connection_t peer = pendingConnections[pid];
            process.connection = peer;
            process.configurationRequest = pendingRequests[pid];
            LCDiscardPendingPeer(pid, peer);
            [process deliverConfiguration];
        }
    });
}

+ (BOOL)startServerWithError:(NSError **)error {
    __block NSError *failure;
    LCWithPlugInState(^{
        if (serverStarted) { failure = listenerError; return; }
        serverStarted = YES;
        NSString *appGroup = LCSharedUtils.appGroupID;
        if (!appGroup.length) {
            failure = listenerError = LCProcessError(@"Missing app group for LivePlugIn communication");
            return;
        }
        NSString *serviceName = LCLivePlugInServiceName(appGroup, getpid());
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t status = bootstrap_check_in(bootstrap_port, serviceName.UTF8String, &service);
        if (status != KERN_SUCCESS || !MACH_PORT_VALID(service)) {
            failure = listenerError = LCProcessError([NSString stringWithFormat:@"Unable to register the LivePlugIn service (bootstrap_check_in: %d)", status]);
            return;
        }
        listener = xpc_connection_create(NULL, serverQueue);
        if (!listener) {
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_RECEIVE, -1);
            failure = listenerError = LCProcessError(@"Unable to create the LivePlugIn XPC listener");
            return;
        }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
                listenerError = LCProcessError(@"The LivePlugIn XPC listener was invalidated");
                if (bootstrapSource) dispatch_source_cancel(bootstrapSource);
                for (xpc_connection_t connection in pendingConnections.allValues) xpc_connection_cancel(connection);
                [pendingConnections removeAllObjects];
                [pendingRequests removeAllObjects];
                for (LCLivePlugIn *process in launches.allValues) [process finishWithError:listenerError];
                return;
            }
            LCAcceptPlugInPeer(peer);
        });
        xpc_connection_resume(listener);

        // The bootstrap pipe only distributes an endpoint. Authentication and
        // launch state stay on serverQueue.
        xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
        dispatch_queue_t queue = dispatch_queue_create("com.kdt.livecontainer.LivePlugIn.bootstrap", DISPATCH_QUEUE_SERIAL);
        bootstrapSource = endpoint ? dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, service, 0, queue) : nil;
        if (!bootstrapSource) {
            xpc_connection_cancel(listener);
            listener = nil;
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_RECEIVE, -1);
            failure = listenerError = LCProcessError(@"Unable to create the LivePlugIn bootstrap receiver");
            return;
        }
        dispatch_source_set_event_handler(bootstrapSource, ^{ @autoreleasepool {
            xpc_object_t request = nil;
            int receiveError = xpc_pipe_receive(service, &request, 0);
            if (receiveError || !request || xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t reply = xpc_dictionary_create_reply(request);
            if (!reply) return;
            audit_token_t audit = {{0}};
            xpc_dictionary_get_audit_token(request, &audit);
            if (audit.val[5] && xpc_dictionary_get_int64(request, "cmd") == LCLivePlugInCommandConnect) {
                xpc_dictionary_set_value(reply, "listener", endpoint);
            } else {
                xpc_dictionary_set_string(reply, "error", "Invalid LivePlugIn connection request");
            }
            xpc_pipe_routine_reply(reply);
        } });
        dispatch_source_set_cancel_handler(bootstrapSource, ^{
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_RECEIVE, -1);
        });
        dispatch_resume(bootstrapSource);
    });
    if (error) *error = failure;
    return failure == nil;
}

- (instancetype)initWithUUID:(NSUUID *)identifier configuration:(NSDictionary *)configuration error:(NSError **)error {
    if (![identifier isKindOfClass:NSUUID.class] || ![configuration isKindOfClass:NSDictionary.class]) {
        if (error) *error = LCProcessError(@"Invalid guest helper launch configuration");
        return nil;
    }
    NSError *archiveError;
    NSData *data;
    @try {
        data = [NSKeyedArchiver archivedDataWithRootObject:configuration requiringSecureCoding:YES error:&archiveError];
    } @catch (NSException *exception) {
        archiveError = LCProcessError(@"The guest helper configuration contains unsupported values");
    }
    if (!data) {
        if (error) *error = archiveError ?: LCProcessError(@"Unable to encode the guest helper configuration");
        return nil;
    }
    if (!(self = [super init])) return nil;
    _identifier = identifier;
    _configurationData = data;
    __block NSError *failure;
    LCWithPlugInState(^{
        if (listenerError) failure = listenerError;
        else if (launches[identifier]) failure = LCProcessError(@"The guest helper request is already starting");
        else launches[identifier] = self;
    });
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LCLivePlugInLaunchTimeout * NSEC_PER_SEC), serverQueue, ^{
        LCLivePlugIn *process = weakSelf;
        if (process) LCExpirePlugIn(process);
    });
    if (error) *error = nil;
    return self;
}

- (void)deliverConfiguration {
    if (!self->_pid || !self.configurationRequest || self.finished) return;
    if (LCXPCConnectionGetPID(self.connection) != self->_pid) {
        [self finishWithError:LCProcessError(@"The helper connection does not match PluginKit's process")];
        return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(self.configurationRequest);
    if (!reply) {
        [self finishWithError:LCProcessError(@"Invalid LivePlugIn launch request")];
        return;
    }
    xpc_dictionary_set_data(reply, "payload", self.configurationData.bytes, self.configurationData.length);
    xpc_connection_send_message(self.connection, reply);
    self.configurationRequest = nil;
    self.configurationData = nil;
}

- (void)finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    self.terminalError = error;
    if (launches[self.identifier] == self) [launches removeObjectForKey:self.identifier];
    xpc_connection_t peer = self.connection;
    if (peer) xpc_connection_cancel(peer);
    self.connection = nil;
    self.configurationRequest = nil;
    self.configurationData = nil;
    if (self->_pid) {
        NSNumber *pid = @(self->_pid);
        xpc_connection_t pending = pendingConnections[pid];
        if (pending) {
            LCDiscardPendingPeer(pid, pending);
            xpc_connection_cancel(pending);
        }
    }
    if (error) {
        [NSUserDefaults.lcUserDefaults setObject:[NSString stringWithFormat:@"LivePlugIn encountered an error: %@", error.localizedDescription] forKey:@"error"];
    }
}

- (void)cancelWithError:(NSError *)error {
    LCWithPlugInState(^{ [self finishWithError:error]; });
}
@end
