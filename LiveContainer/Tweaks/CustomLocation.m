#import "CustomLocation.h"
#import <objc/runtime.h>
#include <stdlib.h>

static CLLocationCoordinate2D LCCustomCoordinate;
static id (*LCOriginalLocationInit)(id, SEL);
static void (*LCOriginalLocationSetDelegate)(id, SEL, id);
static BOOL (*LCOriginalLocationServicesEnabled)(id, SEL);
static id (*LCOriginalLocationDelegate)(id, SEL);
static CLLocation *(*LCOriginalLocationLast)(id, SEL);
static void (*LCOriginalLocationRequest)(id, SEL), (*LCOriginalLocationStart)(id, SEL), (*LCOriginalLocationStop)(id, SEL);
static void (*LCOriginalSignificantStart)(id, SEL), (*LCOriginalSignificantStop)(id, SEL);
static void (*LCOriginalDistanceFilter)(id, SEL, CLLocationDistance);
static Class LCLocationManagerClass;
static char LCLocationProxyKey;
static NSLock *LCLocationLock;
static NSDictionary *LCLocationSnapshot;
static NSHashTable *LCLocationProxies;

static NSDictionary *LCLocationReadSnapshot(void) {
    [LCLocationLock lock];
    NSDictionary *value = LCLocationSnapshot;
    [LCLocationLock unlock];
    return value;
}
static BOOL LCLocationIsEnabled(void) {
    NSDictionary *value = LCLocationReadSnapshot();
    // Lifecycle tests can install the hook directly without a launch snapshot.
    return !value || [value[@"enabled"] boolValue];
}

// Each manager retains its proxy, but neither the delegate nor manager is
// retained by it. Callbacks/timers stay on the manager's creation run loop.
@interface LCLocationDelegateProxy : NSObject <CLLocationManagerDelegate>
@property(nonatomic, weak) CLLocationManager *manager;
@property(nonatomic, weak) id<CLLocationManagerDelegate> target;
@property(nonatomic, strong) NSRunLoop *runLoop;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) CLLocation *lastLocation;
@property(nonatomic) BOOL updating, significant, requesting, deliveredContinuous, deniedReported;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL simulated;
- (void)schedule;
- (void)deliver;
- (void)refreshTimer;
- (void)syncMode;
@end

static LCLocationDelegateProxy *LCProxy(CLLocationManager *manager) {
    return objc_getAssociatedObject(manager, &LCLocationProxyKey);
}

static BOOL LCLocationAuthorized(CLLocationManager *manager) {
    CLAuthorizationStatus status = manager.authorizationStatus;
    return LCOriginalLocationServicesEnabled(LCLocationManagerClass, @selector(locationServicesEnabled)) &&
        (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse);
}

@implementation LCLocationDelegateProxy
- (void)dealloc { [_timer invalidate]; }
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.target respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    id target = self.target;
    return [target respondsToSelector:selector] ? target : [super forwardingTargetForSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature *signature = [super methodSignatureForSelector:selector];
    if (signature) return signature;
    struct objc_method_description method = protocol_getMethodDescription(@protocol(CLLocationManagerDelegate), selector, NO, YES);
    return method.types ? [NSMethodSignature signatureWithObjCTypes:method.types] : [(id)self.target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = self.target;
    if ([target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:target]; return; }
    // Core Location may have cached an optional selector before a weak delegate
    // disappeared. Match sending to nil instead of raising an exception.
    NSUInteger length = invocation.methodSignature.methodReturnLength;
    if (length) {
        void *zero = calloc(1, length);
        [invocation setReturnValue:zero];
        free(zero);
    }
}
- (void)schedule {
    NSUInteger revision = ++self.revision;
    __weak typeof(self) weakSelf = self;
    CFRunLoopRef loop = self.runLoop.getCFRunLoop;
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{
        LCLocationDelegateProxy *proxy = weakSelf;
        if (!proxy || proxy.revision != revision) return;
        [proxy deliver];
        [proxy refreshTimer];
    });
    CFRunLoopWakeUp(loop);
}
- (void)refreshTimer {
    BOOL needsTimer = LCLocationIsEnabled() && self.updating && self.target && LCLocationAuthorized(self.manager) &&
        self.manager.distanceFilter <= 0;
    if (!needsTimer) { [self.timer invalidate]; self.timer = nil; return; }
    if (self.timer) return;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        LCLocationDelegateProxy *proxy = weakSelf;
        if (!proxy) { [timer invalidate]; return; }
        [proxy deliver];
        [proxy refreshTimer];
    }];
    self.timer.tolerance = 0.2;
    [self.runLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)syncMode {
    CLLocationManager *manager = self.manager;
    if (!manager) return;
    BOOL enabled = LCLocationIsEnabled();
    if (self.simulated != enabled) {
        self.simulated = enabled;
        self.lastLocation = nil;
        self.deliveredContinuous = NO;
        if (enabled) {
            if (self.updating || self.requesting) LCOriginalLocationStop(manager, @selector(stopUpdatingLocation));
            if (self.significant) LCOriginalSignificantStop(manager, @selector(stopMonitoringSignificantLocationChanges));
        } else {
            [self.timer invalidate]; self.timer = nil;
            if (self.updating) LCOriginalLocationStart(manager, @selector(startUpdatingLocation));
            else if (self.requesting) LCOriginalLocationRequest(manager, @selector(requestLocation));
            if (self.significant) LCOriginalSignificantStart(manager, @selector(startMonitoringSignificantLocationChanges));
        }
    }
}
- (void)deliver {
    [self syncMode];
    CLLocationManager *manager = self.manager;
    id<CLLocationManagerDelegate> target = self.target;
    if (!LCLocationIsEnabled()) return;
    if (!manager || !target || !(self.requesting || self.updating || self.significant)) return;
    if (!LCLocationAuthorized(manager)) {
        self.lastLocation = nil;
        BOOL denied = manager.authorizationStatus == kCLAuthorizationStatusDenied ||
            manager.authorizationStatus == kCLAuthorizationStatusRestricted ||
            !LCOriginalLocationServicesEnabled(LCLocationManagerClass, @selector(locationServicesEnabled));
        if (denied && !self.deniedReported) {
            self.deniedReported = YES;
            self.requesting = NO;
            if ([target respondsToSelector:@selector(locationManager:didFailWithError:)]) {
                [target locationManager:manager didFailWithError:[NSError errorWithDomain:kCLErrorDomain code:kCLErrorDenied userInfo:nil]];
            }
        }
        return;
    }
    self.deniedReported = NO;
    CLLocation *previous = self.lastLocation;
    NSDictionary *snapshot = LCLocationReadSnapshot();
    CLLocationCoordinate2D coordinate = snapshot ? CLLocationCoordinate2DMake([snapshot[@"latitude"] doubleValue], [snapshot[@"longitude"] doubleValue]) : LCCustomCoordinate;
    double age = NSDate.date.timeIntervalSince1970 - [snapshot[@"timestamp"] doubleValue];
    BOOL freshMotion = age >= 0 && age < 2.5;
    double speed = freshMotion ? [snapshot[@"speed"] doubleValue] : 0;
    double course = speed > 0 ? [snapshot[@"course"] doubleValue] : -1;
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:coordinate altitude:0
        horizontalAccuracy:5 verticalAccuracy:-1 course:course courseAccuracy:-1 speed:speed speedAccuracy:-1
        timestamp:NSDate.date sourceInfo:[[CLLocationSourceInformation alloc] initWithSoftwareSimulationState:YES andExternalAccessoryState:NO]];
    if (!self.requesting && self.deliveredContinuous && previous) {
        // A live snapshot and the idle refresh timer may wake the same manager.
        // Identical snapshots must not produce duplicate samples between ticks.
        if (snapshot && -previous.timestamp.timeIntervalSinceNow < 0.9 &&
            previous.coordinate.latitude == coordinate.latitude && previous.coordinate.longitude == coordinate.longitude &&
            previous.speed == speed && previous.course == course) return;
        double threshold = self.updating ? manager.distanceFilter : 500;
        if (threshold > 0 && [location distanceFromLocation:previous] < threshold) return;
    }
    self.lastLocation = location;
    self.requesting = NO;
    self.deliveredContinuous = YES;
    if ([target respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [target locationManager:manager didUpdateLocations:@[location]];
    } else if ([target respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [target locationManager:manager didUpdateToLocation:location fromLocation:previous];
#pragma clang diagnostic pop
    }
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!LCLocationAuthorized(manager)) self.lastLocation = nil;
    self.deliveredContinuous = NO;
    id<CLLocationManagerDelegate> target = self.target;
    if ([target respondsToSelector:_cmd]) [target locationManagerDidChangeAuthorization:manager];
    else if ([target respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [target locationManager:manager didChangeAuthorizationStatus:manager.authorizationStatus];
#pragma clang diagnostic pop
    }
    [self schedule];
}
- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if (!LCLocationAuthorized(manager)) self.lastLocation = nil;
    self.deliveredContinuous = NO;
    id<CLLocationManagerDelegate> target = self.target;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([target respondsToSelector:_cmd]) [target locationManager:manager didChangeAuthorizationStatus:status];
    else if ([target respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) [target locationManagerDidChangeAuthorization:manager];
#pragma clang diagnostic pop
    [self schedule];
}
// These services are replaced; late system samples must never escape through
// the proxy. Heading/region/visit events are forwarded and are outside scope.
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!LCLocationIsEnabled()) {
        self.requesting = NO;
        if ([self.target respondsToSelector:_cmd]) [self.target locationManager:manager didUpdateLocations:locations];
    }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!LCLocationIsEnabled() && [self.target respondsToSelector:_cmd]) {
        self.requesting = NO;
        [self.target locationManager:manager didUpdateToLocation:newLocation fromLocation:oldLocation];
    }
#pragma clang diagnostic pop
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // Ignore late sensor failures while our covered subscriptions are simulated.
    if (LCLocationIsEnabled()) return;
    if (!LCLocationIsEnabled()) self.requesting = NO;
    if ([self.target respondsToSelector:_cmd]) [self.target locationManager:manager didFailWithError:error];
}
@end

static id LCLocationInit(id manager, SEL selector) {
    manager = LCOriginalLocationInit(manager, selector);
    if (manager && !LCProxy(manager)) {
        LCLocationDelegateProxy *proxy = [LCLocationDelegateProxy new];
        proxy.manager = manager;
        proxy.runLoop = NSRunLoop.currentRunLoop;
        proxy.simulated = LCLocationIsEnabled();
        [LCLocationLock lock]; [LCLocationProxies addObject:proxy]; [LCLocationLock unlock];
        objc_setAssociatedObject(manager, &LCLocationProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LCOriginalLocationSetDelegate(manager, @selector(setDelegate:), proxy);
    }
    return manager;
}
static void LCLocationSetDelegate(CLLocationManager *manager, SEL selector, id delegate) {
    LCLocationDelegateProxy *proxy = LCProxy(manager);
    if (!proxy) { LCOriginalLocationSetDelegate(manager, selector, delegate); return; }
    proxy.target = delegate;
    // Core Location caches optional delegate selectors when assigning it.
    LCOriginalLocationSetDelegate(manager, selector, proxy);
    proxy.revision++;
    proxy.deliveredContinuous = NO;
    proxy.deniedReported = NO;
    [proxy schedule];
}
static id LCLocationDelegate(CLLocationManager *manager, SEL selector) {
    LCLocationDelegateProxy *proxy = LCProxy(manager);
    return proxy ? proxy.target : LCOriginalLocationDelegate(manager, selector);
}
static CLLocation *LCLocationLast(CLLocationManager *manager, SEL selector) {
    LCLocationDelegateProxy *proxy = LCProxy(manager);
    if (!proxy) return LCOriginalLocationLast(manager, selector);
    if (!LCLocationIsEnabled()) return LCOriginalLocationLast(manager, selector);
    return LCLocationAuthorized(manager) ? proxy.lastLocation : nil;
}
static void LCLocationStart(CLLocationManager *manager, SEL selector) {
    LCLocationDelegateProxy *proxy = LCProxy(manager);
    if (!proxy) {
        if (selector == @selector(requestLocation)) LCOriginalLocationRequest(manager, selector);
        else if (selector == @selector(startUpdatingLocation)) LCOriginalLocationStart(manager, selector);
        else LCOriginalSignificantStart(manager, selector);
        return;
    }
    BOOL resumed = proxy.simulated && !LCLocationIsEnabled() &&
        ((selector == @selector(startUpdatingLocation) && proxy.updating) ||
         (selector == @selector(requestLocation) && proxy.requesting && !proxy.updating) ||
         (selector == @selector(startMonitoringSignificantLocationChanges) && proxy.significant));
    [proxy syncMode];
    if (selector == @selector(requestLocation)) proxy.requesting = YES;
    else if (selector == @selector(startMonitoringSignificantLocationChanges)) proxy.significant = YES;
    else proxy.updating = YES;
    proxy.deliveredContinuous = NO;
    proxy.deniedReported = NO;
    if (!LCLocationIsEnabled() && !resumed) {
        if (selector == @selector(requestLocation)) LCOriginalLocationRequest(manager, selector);
        else if (selector == @selector(startUpdatingLocation)) LCOriginalLocationStart(manager, selector);
        else LCOriginalSignificantStart(manager, selector);
    }
    [proxy schedule];
}
static void LCLocationStop(CLLocationManager *manager, SEL selector) {
    LCLocationDelegateProxy *proxy = LCProxy(manager);
    if (!proxy) {
        if (selector == @selector(stopUpdatingLocation)) LCOriginalLocationStop(manager, selector);
        else LCOriginalSignificantStop(manager, selector);
        return;
    }
    [proxy syncMode];
    if (selector == @selector(stopMonitoringSignificantLocationChanges)) proxy.significant = NO;
    else { proxy.updating = NO; proxy.requesting = NO; }
    proxy.revision++;
    [proxy.timer invalidate];
    proxy.timer = nil;
    if (!LCLocationIsEnabled()) {
        if (selector == @selector(stopUpdatingLocation)) LCOriginalLocationStop(manager, selector);
        else LCOriginalSignificantStop(manager, selector);
    }
    if (proxy.updating || proxy.significant || proxy.requesting) [proxy schedule];
}

static void LCLocationDistanceFilter(CLLocationManager *manager, SEL selector, CLLocationDistance distance) {
    LCOriginalDistanceFilter(manager, selector, distance);
    [LCProxy(manager) schedule];
}

static BOOL LCCustomLocationHookClass(Class cls) {
    SEL selectors[] = {@selector(init), @selector(setDelegate:), @selector(delegate), @selector(location),
        @selector(requestLocation), @selector(startUpdatingLocation), @selector(stopUpdatingLocation),
        @selector(startMonitoringSignificantLocationChanges), @selector(stopMonitoringSignificantLocationChanges), @selector(setDistanceFilter:)};
    IMP replacements[] = {(IMP)LCLocationInit, (IMP)LCLocationSetDelegate, (IMP)LCLocationDelegate, (IMP)LCLocationLast,
        (IMP)LCLocationStart, (IMP)LCLocationStart, (IMP)LCLocationStop, (IMP)LCLocationStart, (IMP)LCLocationStop,
        (IMP)LCLocationDistanceFilter};
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(SEL); i++) {
        if (!class_getInstanceMethod(cls, selectors[i])) return NO;
    }
    Method enabled = class_getClassMethod(cls, @selector(locationServicesEnabled));
    if (!enabled) return NO;
    if (!LCLocationLock) LCLocationLock = [NSLock new];
    if (!LCLocationProxies) LCLocationProxies = [NSHashTable weakObjectsHashTable];
    LCLocationManagerClass = cls;
    LCOriginalLocationServicesEnabled = (void *)method_getImplementation(enabled);
    LCOriginalLocationInit = (void *)class_getMethodImplementation(cls, @selector(init));
    LCOriginalLocationSetDelegate = (void *)class_getMethodImplementation(cls, @selector(setDelegate:));
    LCOriginalLocationDelegate = (void *)class_getMethodImplementation(cls, @selector(delegate));
    LCOriginalLocationLast = (void *)class_getMethodImplementation(cls, @selector(location));
    LCOriginalLocationRequest = (void *)class_getMethodImplementation(cls, @selector(requestLocation));
    LCOriginalLocationStart = (void *)class_getMethodImplementation(cls, @selector(startUpdatingLocation));
    LCOriginalLocationStop = (void *)class_getMethodImplementation(cls, @selector(stopUpdatingLocation));
    LCOriginalSignificantStart = (void *)class_getMethodImplementation(cls, @selector(startMonitoringSignificantLocationChanges));
    LCOriginalSignificantStop = (void *)class_getMethodImplementation(cls, @selector(stopMonitoringSignificantLocationChanges));
    LCOriginalDistanceFilter = (void *)class_getMethodImplementation(cls, @selector(setDistanceFilter:));
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(SEL); i++) {
        Method method = class_getInstanceMethod(cls, selectors[i]);
        class_replaceMethod(cls, selectors[i], replacements[i], method_getTypeEncoding(method));
    }
    return YES;
}

void LCCustomLocationInstall(NSDictionary *settings) {
    NSDictionary *valid = LCAppLocationSettings(settings);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCLocationLock = [NSLock new];
        LCLocationProxies = [NSHashTable weakObjectsHashTable];
        LCLocationSnapshot = valid.count ? valid : @{@"enabled": @NO};
        LCCustomCoordinate = CLLocationCoordinate2DMake([valid[@"latitude"] doubleValue], [valid[@"longitude"] doubleValue]);
        LCCustomLocationHookClass(CLLocationManager.class);
    });
}

void LCCustomLocationUpdate(NSDictionary *snapshot) {
    NSDictionary *valid = LCAppLocationSettings(snapshot);
    if (!valid.count && [snapshot[@"enabled"] boolValue]) return;
    NSMutableDictionary *value = [valid mutableCopy];
    if (!value.count) value[@"enabled"] = @NO;
    double speed = [snapshot[@"speed"] doubleValue], course = [snapshot[@"course"] doubleValue];
    value[@"speed"] = @(isfinite(speed) ? fmax(0, fmin(30, speed)) : 0);
    value[@"course"] = @(isfinite(course) && course >= 0 && course < 360 ? course : -1);
    id timestamp = snapshot[@"timestamp"];
    value[@"timestamp"] = [timestamp isKindOfClass:NSNumber.class] && isfinite([timestamp doubleValue]) ? timestamp : @0;
    [LCLocationLock lock];
    if ([LCLocationSnapshot isEqual:value]) { [LCLocationLock unlock]; return; }
    LCLocationSnapshot = value;
    NSArray *proxies = LCLocationProxies.allObjects;
    [LCLocationLock unlock];
    for (LCLocationDelegateProxy *proxy in proxies) {
        __weak LCLocationDelegateProxy *weakProxy = proxy;
        CFRunLoopRef loop = proxy.runLoop.getCFRunLoop;
        CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [weakProxy schedule]; });
        CFRunLoopWakeUp(loop);
    }
}
