#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

// The production host is compiled into this Foundation harness. Only app
// metadata, bookmark grants and PluginKit's system launch callback are fixtures.
// Launch registry and configuration delivery use production code and real XPC.
#import "../LiveContainer/LivePlugInSupport/LivePlugInServer.m"
#import "../LiveContainer/LivePlugInSupport/NSExtension+GuestHooks.m"

static NSUserDefaults *testDefaults;
static NSDictionary *testContainerInfo;
static NSMutableArray<NSURL *> *bookmarkedURLs;
static NSUInteger failBookmarkAt;
static NSDictionary *capturedEnvironment;
static NSUInteger launchCalls;
static NSError *nativeLaunchError;
static NSArray *nativePIDs;
static NSString *testTeamIdentifier;
static NSBundle *testHostBundle;
static bool testIsLiveProcess;
static NSDictionary<NSString *, NSBundle *> *testBundles;
static NSDictionary *capturedDiscoveryAttributes;
static uint64_t capturedDiscoveryFlags;
static id discoveredPlugIn;

@implementation LCSharedUtils
+ (NSString *)appGroupID { return nil; }
+ (NSString *)teamIdentifier { return testTeamIdentifier; }
@end

@implementation NSUserDefaults (GuestPlugInHostTests)
+ (NSUserDefaults *)lcUserDefaults { return testDefaults; }
+ (NSDictionary *)guestContainerInfo { return testContainerInfo ?: @{}; }
+ (NSDictionary *)guestAppInfo { return @{@"helperProcessesSupport": @YES}; }
+ (NSString *)lcAppGroupPath { return nil; }
+ (NSBundle *)lcMainBundle { return testHostBundle; }
+ (bool)isLiveProcess { return testIsLiveProcess; }
@end

@interface NSBundle (GuestPlugInDiscoveryTests)
+ (instancetype)test_bundleWithURL:(NSURL *)url;
@end
@implementation NSBundle (GuestPlugInDiscoveryTests)
+ (instancetype)test_bundleWithURL:(NSURL *)url {
    return testBundles[url.path] ?: [self test_bundleWithURL:url];
}
@end

@interface NSURL (GuestPlugInHostTests)
- (NSData *)test_bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)options
        includingResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys relativeToURL:(NSURL *)relativeURL error:(NSError **)error;
@end

@implementation NSURL (GuestPlugInHostTests)
- (NSData *)test_bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)options
        includingResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys relativeToURL:(NSURL *)relativeURL error:(NSError **)error {
    (void)options; (void)keys; (void)relativeURL;
    [bookmarkedURLs addObject:self];
    if (failBookmarkAt && bookmarkedURLs.count == failBookmarkAt) {
        if (error) *error = [NSError errorWithDomain:@"bookmark-fixture" code:17 userInfo:nil];
        return nil;
    }
    if (error) *error = nil;
    return [self.path dataUsingEncoding:NSUTF8StringEncoding];
}
@end

@interface LCTestGuestBundle : NSObject
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *bundlePath;
@property(nonatomic, readonly) NSURL *bundleURL;
@property(nonatomic, readonly) NSURL *builtInPlugInsURL;
@end
@implementation LCTestGuestBundle
- (NSURL *)bundleURL { return [NSURL fileURLWithPath:self.bundlePath isDirectory:YES]; }
- (NSURL *)builtInPlugInsURL { return [self.bundleURL URLByAppendingPathComponent:@"PlugIns" isDirectory:YES]; }
@end

@interface LCTestPlugInTarget : NSObject
@property(nonatomic, strong) NSUUID *uuid;
- (id)createInstanceWithUUID:(NSUUID *)uuid;
@end
@implementation LCTestPlugInTarget
- (id)createInstanceWithUUID:(NSUUID *)uuid {
    LCTestPlugInTarget *instance = [LCTestPlugInTarget new];
    instance.uuid = uuid;
    return instance;
}
@end

static void nativeReady(id object, SEL selector, NSArray *plugins, bool synchronously,
        id environment, id languages, id persona, id sandbox,
        void (^ready)(NSError *, NSArray *, NSArray *)) {
    (void)object; (void)selector; (void)synchronously; (void)languages; (void)persona; (void)sandbox;
    launchCalls++;
    capturedEnvironment = [environment copy];
    if (ready) ready(nativeLaunchError, nativePIDs ?: @[@43210], @[[plugins.firstObject uuid] ?: NSUUID.UUID]);
}

static void resetRegistry(void) {
    LCWithPlugInState(^{
        for (LCLivePlugIn *process in launches.allValues) [process finishWithError:nil];
        for (xpc_connection_t peer in pendingConnections.allValues) xpc_connection_cancel(peer);
        [pendingConnections removeAllObjects];
        [pendingRequests removeAllObjects];
        listenerError = nil;
        serverStarted = YES; // Skip named Mach bootstrap; real anonymous XPC is exercised below.
    });
    bookmarkedURLs = [NSMutableArray array];
    failBookmarkAt = 0;
    capturedEnvironment = nil;
    nativeLaunchError = nil;
    nativePIDs = nil;
    launchCalls = 0;
    orig_readyPlugIns = nativeReady;
}

static LCTestGuestBundle *guestBundle(void) {
    LCTestGuestBundle *bundle = [LCTestGuestBundle new];
    bundle.bundleIdentifier = @"com.example.guest.helper";
    bundle.bundlePath = [guestExtensionsAppURL.path stringByAppendingPathComponent:@"PlugIns/Helper.appex"];
    return bundle;
}

static LCTestPlugInTarget *guestPlugIn(LCTestGuestBundle *bundle) {
    LCTestPlugInTarget *plugin = [LCTestPlugInTarget new];
    plugin.uuid = NSUUID.UUID;
    if (bundle) objc_setAssociatedObject(plugin, guestBundleKey, bundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return plugin;
}

static void testBookmarksAndPreparationErrors(void) {
    resetRegistry();
    NSError *error;
    NSDictionary *configuration = prepareGuestPlugInConfig((id)guestBundle(), &error);
    assert(configuration && !error);
    assert(bookmarkedURLs.count == 4);
    assert([bookmarkedURLs.lastObject isEqual:guestExtensionsContainerURL]);
    assert([configuration[@"parentContainerPath"] isEqual:guestExtensionsContainerURL.path]);
    assert([configuration[@"bookmarks"] count] == 4);
    for (NSUInteger failure = 1; failure <= 4; failure++) {
        bookmarkedURLs = [NSMutableArray array];
        failBookmarkAt = failure;
        error = nil;
        assert(!prepareGuestPlugInConfig((id)guestBundle(), &error));
        assert([error.domain isEqual:@"bookmark-fixture"] && error.code == 17);
    }
    failBookmarkAt = 0;
    LCTestGuestBundle *invalid = guestBundle();
    invalid.bundleIdentifier = @"";
    assert(!prepareGuestPlugInConfig((id)invalid, &error) && error);
}

static void testLaunchRoutingAndFailurePropagation(void) {
    resetRegistry();
    NSDictionary *environment = @{@"LC_LIVEPLUGIN": @"1", @"UNCHANGED": @"value"};
    LCTestPlugInTarget *ordinary = guestPlugIn(nil);
    hook_readyPlugIns(nil, NULL, (id)@[ordinary], NO, environment, @[], nil, nil, nil);
    assert(launchCalls == 1 && !capturedEnvironment[@"LC_LIVEPLUGIN"]);
    assert([capturedEnvironment[@"UNCHANGED"] isEqual:@"value"]);
    assert([environment[@"LC_LIVEPLUGIN"] isEqual:@"1"]);

    resetRegistry();
    LCTestPlugInTarget *guest = guestPlugIn(guestBundle());
    __block NSUInteger callbacks = 0;
    hook_readyPlugIns(nil, NULL, (id)@[guest], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        assert(!error && pids.count == 1 && uuids.count == 1); callbacks++;
    });
    assert(launchCalls == 1 && callbacks == 1);
    assert([capturedEnvironment[@"LC_LIVEPLUGIN"] isEqual:@"1"]);
    LCWithPlugInState(^{ assert(launches[guest.uuid].pid == 43210); });

    // A second UUID cannot claim another launch's PID, and the caller must see
    // the bind failure instead of a successful native PluginKit callback.
    __block NSError *duplicatePIDError;
    hook_readyPlugIns(nil, NULL, (id)@[guestPlugIn(guestBundle())], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        (void)pids; (void)uuids; duplicatePIDError = error;
    });
    assert(duplicatePIDError);
    LCWithPlugInState(^{ assert(launches.count == 1 && launches[guest.uuid]); });

    resetRegistry();
    failBookmarkAt = 4;
    __block NSError *failure;
    hook_readyPlugIns(nil, NULL, (id)@[guest], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        failure = error; assert(!pids && !uuids);
    });
    assert(launchCalls == 0 && [failure.domain isEqual:@"bookmark-fixture"]);

    resetRegistry();
    LCWithPlugInState(^{ listenerError = LCProcessError(@"bootstrap unavailable"); });
    failure = nil;
    hook_readyPlugIns(nil, NULL, (id)@[guest], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        failure = error; assert(!pids && !uuids);
    });
    assert(launchCalls == 0 && [failure.localizedDescription isEqual:@"bootstrap unavailable"]);

    resetRegistry();
    nativeLaunchError = LCProcessError(@"native launch cancelled");
    failure = nil;
    hook_readyPlugIns(nil, NULL, (id)@[guest], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        (void)pids; (void)uuids; failure = error;
    });
    assert(failure == nativeLaunchError);
    LCWithPlugInState(^{ assert(!launches.count); });

    resetRegistry();
    nativePIDs = @[];
    failure = nil;
    hook_readyPlugIns(nil, NULL, (id)@[guest], NO, environment, @[], nil, nil, ^(NSError *error, NSArray *pids, NSArray *uuids) {
        (void)pids; (void)uuids; failure = error;
    });
    assert(failure);
    LCWithPlugInState(^{ assert(!launches.count); });
}

static void testDiscoveryProxyOwnsTarget(void) {
    __weak LCTestPlugInTarget *weakTarget;
    PKHostPluginProxy *proxy;
    LCTestGuestBundle *bundle = guestBundle();
    @autoreleasepool {
        LCTestPlugInTarget *target = guestPlugIn(nil);
        weakTarget = target;
        proxy = [[PKHostPluginProxy alloc] initWithTarget:(id)target guestBundle:(id)bundle];
    }
    @autoreleasepool {
        assert(weakTarget);
        NSUUID *uuid = NSUUID.UUID;
        LCTestPlugInTarget *instance = [(id)proxy createInstanceWithUUID:uuid];
        assert([instance.uuid isEqual:uuid]);
        assert(objc_getAssociatedObject(instance, guestBundleKey) == bundle);
    }
    proxy = nil;
    assert(!weakTarget);
}

static void nativeDiscover(id object, SEL selector, NSDictionary *attributes, uint64_t flags,
        void (^found)(NSSet *, NSError *)) {
    (void)object; (void)selector;
    capturedDiscoveryAttributes = [attributes copy];
    capturedDiscoveryFlags = flags;
    if (found) found([NSSet setWithObject:discoveredPlugIn], nil);
}

static void testDiscoveryFromPrimaryAndExtraContainers(void) {
    LCTestGuestBundle *guest = guestBundle();
    NSURL *guestURL = guest.bundleURL;
    assert([NSFileManager.defaultManager createDirectoryAtURL:guestURL withIntermediateDirectories:YES attributes:nil error:nil]);
    LCTestGuestBundle *host = [LCTestGuestBundle new];
    LCTestGuestBundle *helper = [LCTestGuestBundle new];
    helper.bundleIdentifier = @"custom.signed.LiveProcess";
    testHostBundle = (id)host;
    testTeamIdentifier = @"TESTTEAM42";
    discoveredPlugIn = guestPlugIn(nil);
    orig_discoverPlugInsForAttributes = nativeDiscover;
    Method nativeBundle = class_getClassMethod(NSBundle.class, @selector(bundleWithURL:));
    Method fixtureBundle = class_getClassMethod(NSBundle.class, @selector(test_bundleWithURL:));
    method_exchangeImplementations(nativeBundle, fixtureBundle);

    NSDictionary *attributes = @{@"NSExtensionIdentifier": guest.bundleIdentifier, @"NSExtensionPointName": @"keep-filter"};
    void (^verify)(NSString *, BOOL) = ^(NSString *expectedIdentifier, BOOL proxyExpected) {
        __block BOOL called = NO;
        hook_discoverPlugInsForAttributes(nil, NULL, attributes, 73, ^(NSSet *result, NSError *error) {
            called = YES;
            assert(!error && result.count == 1);
            id plugin = result.anyObject;
            if (proxyExpected) {
                assert(plugin != discoveredPlugIn);
                assert([(PKHostPluginProxy *)plugin target] == discoveredPlugIn);
                assert([(PKHostPluginProxy *)plugin guestBundle] == (id)guest);
            } else assert(plugin == discoveredPlugIn);
        });
        assert(called && capturedDiscoveryFlags == 73);
        assert([capturedDiscoveryAttributes[@"NSExtensionIdentifier"] isEqual:expectedIdentifier]);
        assert([capturedDiscoveryAttributes[@"NSExtensionPointName"] isEqual:@"keep-filter"]);
        assert([attributes[@"NSExtensionIdentifier"] isEqual:guest.bundleIdentifier]);
    };

    // LC2/LC3 have no embedded helper and use LC1's signed identifier.
    for (NSString *name in @[@"LC2.app", @"LC3.app"]) {
        host.bundlePath = [[guestExtensionsAppURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:name] path];
        testBundles = @{guestURL.path: (id)guest};
        testIsLiveProcess = false;
        verify(@"com.kdt.livecontainer.TESTTEAM42.LiveProcess", YES);
    }
    // Embedded and sibling helpers take precedence over the guessed identifier.
    testBundles = @{guestURL.path: (id)guest,
        [host.builtInPlugInsURL URLByAppendingPathComponent:@"LiveProcess.appex"].path: (id)helper};
    verify(helper.bundleIdentifier, YES);
    testIsLiveProcess = true;
    testBundles = @{guestURL.path: (id)guest,
        [host.bundleURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"LiveProcess.appex"].path: (id)helper};
    verify(helper.bundleIdentifier, YES);

    // Missing signing identity cannot turn into a malformed discovery request.
    testBundles = @{guestURL.path: (id)guest};
    testTeamIdentifier = nil;
    verify(guest.bundleIdentifier, NO);
    testTeamIdentifier = @"";
    verify(guest.bundleIdentifier, NO);
    // Unknown extensions retain their original lookup even when LC1 is available.
    testTeamIdentifier = @"TESTTEAM42";
    NSDictionary *ordinary = @{@"NSExtensionIdentifier": @"ordinary.extension", @"other-filter": @YES};
    hook_discoverPlugInsForAttributes(nil, NULL, ordinary, 29, nil);
    assert([capturedDiscoveryAttributes isEqual:ordinary] && capturedDiscoveryFlags == 29);

    method_exchangeImplementations(nativeBundle, fixtureBundle);
    testBundles = nil;
    testHostBundle = nil;
    testTeamIdentifier = nil;
    testIsLiveProcess = false;
    discoveredPlugIn = nil;
}

static void testConcurrentRegistrationAndTerminalCleanup(void) {
    resetRegistry();
    dispatch_apply(40, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) { @autoreleasepool {
        NSError *error;
        LCLivePlugIn *process = [[LCLivePlugIn alloc] initWithUUID:NSUUID.UUID configuration:@{@"index": @(index)} error:&error];
        assert(process && !error);
        assert([process bindToPID:(pid_t)(50000 + index) error:&error] && !error);
        assert(process.pid == (pid_t)(50000 + index));
        [process cancelWithError:nil];
        // A late PluginKit callback cannot resurrect the launch.
        assert(![process bindToPID:(pid_t)(60000 + index) error:&error] && error);
        assert(process.pid == (pid_t)(50000 + index));
    } });
    LCWithPlugInState(^{ assert(!launches.count && !pendingConnections.count && !pendingRequests.count); });
    NSError *error;
    NSUUID *identifier = NSUUID.UUID;
    LCLivePlugIn *process = [[LCLivePlugIn alloc] initWithUUID:identifier configuration:@{} error:&error];
    assert(process && !error);
    assert(![[LCLivePlugIn alloc] initWithUUID:identifier configuration:@{} error:&error] && error);
    LCWithPlugInState(^{ LCExpirePlugIn(process); assert(!launches[identifier]); });
    assert(![process bindToPID:70123 error:&error] && error);
    assert(process.pid == 0);
    assert(![[LCLivePlugIn alloc] initWithUUID:NSUUID.UUID configuration:(id)@"not a dictionary" error:&error] && error);
    assert(![[LCLivePlugIn alloc] initWithUUID:NSUUID.UUID configuration:@{@"unsupported": [NSObject new]} error:&error] && error);
}

static dispatch_time_t testDeadline(void) { return dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC); }

static void testConfigurationWithRealXPC(BOOL requestFirst) {
    resetRegistry();
    NSDictionary *configuration = @{@"bundlePath": @"/fixture/helper.appex", @"bookmarks": @[[NSData data]], @"options": @{@"enabled": @YES}};
    NSError *error;
    LCLivePlugIn *process = [[LCLivePlugIn alloc] initWithUUID:NSUUID.UUID configuration:configuration error:&error];
    assert(process && !error);
    dispatch_semaphore_t receivedRequest = dispatch_semaphore_create(0);
    dispatch_semaphore_t receivedReply = dispatch_semaphore_create(0);
    dispatch_semaphore_t disconnected = dispatch_semaphore_create(0);
    __block xpc_connection_t retainedPeer;
    xpc_connection_t testListener = xpc_connection_create(NULL, serverQueue);
    xpc_connection_set_event_handler(testListener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        retainedPeer = peer;
        xpc_connection_set_target_queue(peer, serverQueue);
        __weak xpc_connection_t weakPeer = peer;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            xpc_connection_t connection = weakPeer;
            if (!connection) return;
            LCHandlePlugInPeerEvent(connection, event);
            if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) dispatch_semaphore_signal(receivedRequest);
            else if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                retainedPeer = nil;
                dispatch_semaphore_signal(disconnected);
            }
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(testListener);
    xpc_endpoint_t endpoint = xpc_endpoint_create(testListener);
    xpc_connection_t client = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_set_event_handler(client, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(client);
    if (!requestFirst) assert([process bindToPID:getpid() error:&error] && !error);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(request, "cmd", LCLivePlugInCommandLaunchConfiguration);
    __block NSDictionary *decoded;
    xpc_connection_send_message_with_reply(client, request, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(xpc_object_t reply) {
        assert(xpc_get_type(reply) == XPC_TYPE_DICTIONARY);
        size_t length = 0;
        const void *bytes = xpc_dictionary_get_data(reply, "payload", &length);
        assert(bytes && length);
        NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSData.class, nil];
        decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:[NSData dataWithBytes:bytes length:length] error:nil];
        dispatch_semaphore_signal(receivedReply);
    });
    assert(dispatch_semaphore_wait(receivedRequest, testDeadline()) == 0);
    if (requestFirst) {
        LCWithPlugInState(^{ assert(pendingRequests.count == 1 && !process.connection); });
        assert([process bindToPID:getpid() error:&error] && !error);
    }
    assert(dispatch_semaphore_wait(receivedReply, testDeadline()) == 0);
    assert([decoded isEqual:configuration]);
    LCWithPlugInState(^{ assert(!pendingRequests.count && !pendingConnections.count && !process.configurationData); });
    xpc_connection_cancel(client);
    assert(dispatch_semaphore_wait(disconnected, testDeadline()) == 0);
    LCWithPlugInState(^{ assert(!launches.count && process.finished); });
    xpc_connection_cancel(testListener);
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"lc-tests.guest-plugin." stringByAppendingString:NSUUID.UUID.UUIDString];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:suite] isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
        guestExtensionsAppURL = [root URLByAppendingPathComponent:@"Guest.app" isDirectory:YES];
        guestExtensionsContainerURL = [root URLByAppendingPathComponent:@"Parent" isDirectory:YES];
        setenv("LC_HOME_PATH", root.path.UTF8String, 1);
        testContainerInfo = @{@"isolateAppGroup": @YES};
        Method realBookmark = class_getInstanceMethod(NSURL.class, @selector(bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:));
        Method testBookmark = class_getInstanceMethod(NSURL.class, @selector(test_bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:));
        method_exchangeImplementations(realBookmark, testBookmark);
        testBookmarksAndPreparationErrors();
        testLaunchRoutingAndFailurePropagation();
        testDiscoveryProxyOwnsTarget();
        testDiscoveryFromPrimaryAndExtraContainers();
        testConcurrentRegistrationAndTerminalCleanup();
        testConfigurationWithRealXPC(NO);
        testConfigurationWithRealXPC(YES);
        resetRegistry();
        method_exchangeImplementations(realBookmark, testBookmark);
        [testDefaults removePersistentDomainForName:suite];
        assert([NSFileManager.defaultManager removeItemAtURL:root error:nil]);
    }
    puts("Guest plugin host tests passed (parent grants, LC1/LC2/LC3 discovery, launch routing/errors, proxy lifetime, concurrent cleanup and real XPC configuration delivery)");
    return 0;
}
