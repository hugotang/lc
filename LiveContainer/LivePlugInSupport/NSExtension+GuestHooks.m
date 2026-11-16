#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "../FoundationPrivate.h"
#import "PlugInKitPrivate.h"
#import "LivePlugInServer.h"
#import "../utils.h"
#import "Tweaks.h"

static NSURL *guestExtensionsAppURL;
static NSURL *guestExtensionsContainerURL;

static NSError *LCGuestExtensionError(NSString *message) {
    return [NSError errorWithDomain:@"LCGuestExtension" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSDictionary* prepareGuestPlugInConfig(NSBundle* guestBundle, NSError** errorOut) {
    NSError *error = nil;
    const char *lcHome = getenv("LC_HOME_PATH");
    if (!guestExtensionsAppURL || !guestExtensionsContainerURL || !lcHome || !lcHome[0]) {
        if (errorOut) *errorOut = LCGuestExtensionError(@"The guest helper's parent container is unavailable");
        return nil;
    }
    // Bundle identifiers are metadata from an imported app. Encode them as one
    // path component so a malformed identifier cannot escape the subcontainer.
    NSString *component = [guestBundle.bundleIdentifier stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    if (component.length == 0) {
        if (errorOut) *errorOut = LCGuestExtensionError(@"The extension has no bundle identifier");
        return nil;
    }
    NSURL *containerURL = [[guestExtensionsContainerURL URLByAppendingPathComponent:@"Extensions" isDirectory:YES] URLByAppendingPathComponent:component isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *directory in @[@"Documents", @"Library/Caches", @"Library/Preferences", @"tmp"]) {
        if (![fm createDirectoryAtURL:[containerURL URLByAppendingPathComponent:directory] withIntermediateDirectories:YES attributes:nil error:&error]) break;
    }
    NSMutableArray *bookmarks = [NSMutableArray array];
    NSString *appGroupPath;
    if ([NSUserDefaults.guestContainerInfo[@"isolateAppGroup"] boolValue]) {
        appGroupPath = [guestExtensionsContainerURL.path stringByAppendingPathComponent:@"LCAppGroup"];
    } else if (NSUserDefaults.lcAppGroupPath.length) {
        appGroupPath = [NSUserDefaults.lcAppGroupPath stringByAppendingPathComponent:@"LiveContainer/Data/AppGroup"];
    } else {
        appGroupPath = [@(lcHome) stringByAppendingPathComponent:@"Documents/Data/AppGroup"];
    }
    if (!error) [fm createDirectoryAtPath:appGroupPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error) {
        // Shared preference suites live in the parent's container. Passing a
        // path alone does not give the helper permission to read those files.
        for (NSURL *url in @[guestExtensionsAppURL, containerURL, [NSURL fileURLWithPath:appGroupPath isDirectory:YES], guestExtensionsContainerURL]) {
            NSData *bookmark = [url bookmarkDataWithOptions:(1 << 11) includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!bookmark) break;
            [bookmarks addObject:bookmark];
        }
    }
    if (error || bookmarks.count != 4) {
        if (errorOut) *errorOut = error ?: LCGuestExtensionError(@"Unable to share the extension container");
        return nil;
    }


    NSDictionary *envelope = @{
            @"bundlePath": guestBundle.bundlePath,
            @"appBundlePath": guestExtensionsAppURL.path,
            @"containerPath": containerURL.path,
            @"bookmarks": bookmarks,
            @"guestAppInfo": NSUserDefaults.guestAppInfo ?: @{},
            @"guestContainerInfo": NSUserDefaults.guestContainerInfo ?: @{},
            @"appGroupPath": NSUserDefaults.lcAppGroupPath ?: @"",
            @"parentContainerPath": guestExtensionsContainerURL.path,
            @"lcHomePath": @(lcHome),
    };

    if (errorOut) *errorOut = nil;
    return envelope;
}

static NSBundle *LCFindGuestExtension(NSString *identifier) {
    NSURL *pluginsURL = [guestExtensionsAppURL URLByAppendingPathComponent:@"PlugIns" isDirectory:YES];
    NSArray<NSURL *> *plugins = [NSFileManager.defaultManager contentsOfDirectoryAtURL:pluginsURL includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *url in plugins) {
        if (![url.pathExtension isEqualToString:@"appex"]) continue;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        if ([bundle.bundleIdentifier isEqualToString:identifier]) return bundle;
    }
    return nil;
}

@interface PKHostPluginProxy : NSProxy
@property (nonatomic, strong, readonly) PKHostPlugIn* target;
@property(nonatomic, strong) NSBundle* guestBundle;
- (instancetype)initWithTarget:(id)target guestBundle:(NSBundle*)guestBundle;
@end
void* guestBundleKey = &guestBundleKey;

void (*orig_discoverPlugInsForAttributes)(id self, SEL _cmd, NSDictionary* attributes, uint64_t flags, void (^found)(NSSet*, NSError *));
void hook_discoverPlugInsForAttributes(id self, SEL _cmd, NSDictionary* attributes, uint64_t flags, void (^found)(NSSet*, NSError *)) {
    NSString* identifier = attributes[@"NSExtensionIdentifier"];
    NSBundle *bundle = LCFindGuestExtension(identifier);

    if(!bundle) {
        orig_discoverPlugInsForAttributes(self, _cmd, attributes, flags, found);
        return;
    }

    NSBundle *liveProcessBundle;
    if(NSUserDefaults.isLiveProcess) {
        liveProcessBundle = [NSBundle bundleWithURL:[NSUserDefaults.lcMainBundle.bundleURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"LiveProcess.appex"]];
    } else {
        liveProcessBundle = [NSBundle bundleWithURL:[NSUserDefaults.lcMainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"LiveProcess.appex"]];
    }
    if (!liveProcessBundle.bundleIdentifier) {
        NSLog(@"LivePlugIn is missing. Reinstall LiveContainer and keep its extensions.");
        orig_discoverPlugInsForAttributes(self, _cmd, attributes, flags, found);
        return;
    }
    NSMutableDictionary *newAttributes = [attributes mutableCopy];
    newAttributes[@"NSExtensionIdentifier"] = liveProcessBundle.bundleIdentifier;
    orig_discoverPlugInsForAttributes(self, _cmd, newAttributes, flags, ^(NSSet* result, NSError* err) {
        if([result count] == 1) {
            NSMutableSet* result2 = [result mutableCopy];
            id old = [result2 anyObject];
            [result2 removeObject:old];
            [result2 addObject:[[PKHostPluginProxy alloc] initWithTarget:old guestBundle:bundle]];
            found(result2, err);
        } else {
            found(result, err);
        }
    });
}

void (*orig_readyPlugIns)(id self, SEL _cmd, NSArray<PKHostPlugIn*>* plugins, bool synchronously, id environment, id languages, id persona, id sandbox, void (^ready)(NSError *error,NSArray<NSNumber *> *pids,NSArray<NSUUID *> *uuids) );
void hook_readyPlugIns(id self, SEL _cmd, NSArray<PKHostPlugIn*>* plugins, bool synchronously, id environment, id languages, id persona, id sandbox, void (^ready)(NSError *error,NSArray<NSNumber *> *pids,NSArray<NSUUID *> *uuids) ){
    PKHostPlugIn* plugin = plugins.firstObject;
    NSBundle* guestBundle = plugin ? objc_getAssociatedObject(plugin, guestBundleKey) : nil;
    NSMutableDictionary *launchEnvironment = [environment isKindOfClass:NSDictionary.class] ? [environment mutableCopy] : [NSMutableDictionary dictionary];
    // A guest can forward its inherited environment to another extension.
    // Only launches explicitly associated with a guest bundle carry this flag.
    [launchEnvironment removeObjectForKey:@(LCLivePlugInEnvironmentKey)];
    if([plugins count] != 1 || !plugin || !guestBundle) {
        id passthroughEnvironment = [environment isKindOfClass:NSDictionary.class] ? launchEnvironment : environment;
        orig_readyPlugIns(self, _cmd, plugins, synchronously, passthroughEnvironment, languages, persona, sandbox, ready);
        return;
    }

    NSError *preparationError;
    NSDictionary *configuration = prepareGuestPlugInConfig(guestBundle, &preparationError);
    if (!configuration || ![LCLivePlugIn startServerWithError:&preparationError]) {
        if (ready) ready(preparationError ?: LCGuestExtensionError(@"Unable to prepare the guest helper"), nil, nil);
        return;
    }
    LCLivePlugIn *lp = [[LCLivePlugIn alloc] initWithUUID:[plugin uuid] configuration:configuration error:&preparationError];
    if (!lp) {
        if (ready) ready(preparationError, nil, nil);
        return;
    }
    launchEnvironment[@(LCLivePlugInEnvironmentKey)] = @"1";

    orig_readyPlugIns(self, _cmd, plugins, synchronously, launchEnvironment, languages, persona, sandbox, ^(NSError *error, NSArray<NSNumber *> *pids,NSArray<NSUUID *> *uuids) {
        NSNumber *pid = pids.firstObject;
        if (!error && (![pid isKindOfClass:NSNumber.class] || pid.intValue <= 0)) {
            error = LCGuestExtensionError(@"PluginKit did not return a helper process");
        }
        if (error) [lp cancelWithError:error];
        else [lp bindToPID:pid.intValue error:&error];
        if (ready) ready(error, pids, uuids);
    });
}

@implementation PKHostPluginProxy : NSProxy

- (instancetype)initWithTarget:(PKHostPlugIn*)target guestBundle:(NSBundle*)guestBundle {
    _target = target;
    _guestBundle = guestBundle;
    return self;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [self.target methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:self.target];
    if(strcmp(sel_getName(invocation.selector), "createInstanceWithUUID:") == 0) {
        __unsafe_unretained id tempReturnValue = nil;
        [invocation getReturnValue:&tempReturnValue];
        PKHostPlugIn* newPlugIn = tempReturnValue;
        if (newPlugIn) objc_setAssociatedObject(newPlugIn, guestBundleKey, _guestBundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end

void NSExtensionGuestHooksInit(NSURL *appURL, NSURL *containerURL) {
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_LAZY | RTLD_GLOBAL);

    guestExtensionsAppURL = appURL;
    guestExtensionsContainerURL = containerURL;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincompatible-function-pointer-types"
    Class PKHostClass = NSClassFromString(@"PKHost");

    Method m1 = class_getInstanceMethod(PKHostClass, @selector(discoverPlugInsForAttributes:flags:found:));
    Method m2 = class_getInstanceMethod(PKHostClass, @selector(readyPlugIns:synchronously:environment:languages:persona:sandbox:ready:));
    if (!m1 || !m2 || orig_discoverPlugInsForAttributes || orig_readyPlugIns) return;
    orig_discoverPlugInsForAttributes = method_getImplementation(m1);
    orig_readyPlugIns = method_getImplementation(m2);
    method_setImplementation(m1, hook_discoverPlugInsForAttributes);
    method_setImplementation(m2, hook_readyPlugIns);

#pragma clang diagnostic pop

}

@implementation NSXPCListener(hook)

- (instancetype)hook_initWithMachServiceName:(NSString*)serviceName {
    NSString* newServiceName = serviceName;
    NSString* guestBundleId = NSBundle.mainBundle.bundleIdentifier;
    if(guestBundleId.length && ([serviceName isEqualToString:guestBundleId] ||
        [serviceName hasPrefix:[guestBundleId stringByAppendingString:@"."]])) {
        NSString *remaining = [serviceName substringFromIndex:guestBundleId.length];
        newServiceName = [NSUserDefaults.lcMainBundle.bundleIdentifier stringByAppendingString:remaining];
    }
    return [self hook_initWithMachServiceName:newServiceName];
}

@end

// when running as a guest extension
void GuestExtensionHooksInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        swizzle(NSXPCListener.class, @selector(initWithMachServiceName:), @selector(hook_initWithMachServiceName:));
    });
}
