#import <XCTest/XCTest.h>
#import "../LiveContainer/Tweaks/CustomLocation.m"

// Hook a manager double with the same public contract, keeping the simulator's
// location manager and permission dialogs intact for other UIKit tests.
static BOOL LCTestServicesEnabled = YES;
@interface LCTestLocationManager : NSObject
@property(nonatomic, weak) id<CLLocationManagerDelegate> delegate;
@property(nonatomic) CLAuthorizationStatus authorizationStatus;
@property(nonatomic) CLLocationDistance distanceFilter;
@property(nonatomic, strong) CLLocation *location;
@property(nonatomic) NSUInteger originalRequests, permissionRequests;
+ (BOOL)locationServicesEnabled;
- (void)requestLocation;
- (void)startUpdatingLocation;
- (void)stopUpdatingLocation;
- (void)startMonitoringSignificantLocationChanges;
- (void)stopMonitoringSignificantLocationChanges;
- (void)requestWhenInUseAuthorization;
@end
@implementation LCTestLocationManager
- (instancetype)init {
    if ((self = [super init])) { _authorizationStatus = kCLAuthorizationStatusAuthorizedWhenInUse; _distanceFilter = -1; }
    return self;
}
+ (BOOL)locationServicesEnabled { return LCTestServicesEnabled; }
- (void)requestLocation { self.originalRequests++; }
- (void)startUpdatingLocation { self.originalRequests++; }
- (void)stopUpdatingLocation {}
- (void)startMonitoringSignificantLocationChanges { self.originalRequests++; }
- (void)stopMonitoringSignificantLocationChanges {}
- (void)requestWhenInUseAuthorization { self.permissionRequests++; }
@end

@interface LCTestLocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic, strong) NSMutableArray<CLLocation *> *locations;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) NSUInteger authorizations, headings;
@property(nonatomic, strong) NSThread *callbackThread;
@property(nonatomic, copy) void (^onUpdate)(void);
@end
@implementation LCTestLocationDelegate
- (instancetype)init { if ((self = [super init])) _locations = [NSMutableArray new]; return self; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    [self.locations addObjectsFromArray:locations]; self.callbackThread = NSThread.currentThread;
    if (self.onUpdate) self.onUpdate();
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error { self.error = error; }
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager { self.authorizations++; }
- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading { self.headings++; }
@end

@interface LCTestLegacyLocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic) NSUInteger authorizations, updates;
@end
@implementation LCTestLegacyLocationDelegate
- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status { self.authorizations++; }
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation { self.updates++; }
@end

@interface CustomLocationTests : XCTestCase
@property(nonatomic, strong) LCTestLocationManager *manager;
@property(nonatomic, strong) LCTestLocationDelegate *receiver;
@end
@implementation CustomLocationTests
- (void)setUp {
    [super setUp];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ XCTAssertTrue(LCCustomLocationHookClass(LCTestLocationManager.class)); });
    LCTestServicesEnabled = YES;
    LCCustomCoordinate = CLLocationCoordinate2DMake(22.3193, 114.1694);
    self.manager = [LCTestLocationManager new];
    self.receiver = [LCTestLocationDelegate new];
    self.manager.delegate = self.receiver;
}
- (void)tearDown {
    [self.manager stopUpdatingLocation];
    [self.manager stopMonitoringSignificantLocationChanges];
    self.manager.delegate = nil;
    self.receiver = nil; self.manager = nil;
    [super tearDown];
}
- (LCLocationDelegateProxy *)proxy { return LCProxy((id)self.manager); }
- (void)drain {
    XCTestExpectation *e = [self expectationWithDescription:@"run loop"];
    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), kCFRunLoopCommonModes, ^{ [e fulfill]; });
    CFRunLoopWakeUp(CFRunLoopGetCurrent());
    [self waitForExpectations:@[e] timeout:2];
}
- (void)testOneShotUsesFixedLocationAndLeavesOrdinaryCoordinatesUntouched {
    XCTAssertNil(self.manager.location);
    XCTAssertEqual(self.manager.delegate, self.receiver);
    [self.manager requestLocation];
    XCTAssertEqual(self.receiver.locations.count, 0u);
    [self drain];
    XCTAssertEqual(self.receiver.locations.count, 1u);
    CLLocation *value = self.receiver.locations.lastObject;
    XCTAssertEqualWithAccuracy(value.coordinate.latitude, 22.3193, 0.000001);
    XCTAssertEqualWithAccuracy(value.coordinate.longitude, 114.1694, 0.000001);
    XCTAssertLessThan(fabs(value.timestamp.timeIntervalSinceNow), 2);
    XCTAssertEqual(value.speed, 0);
    XCTAssertEqual(value.course, -1);
    XCTAssertTrue(value.sourceInformation.isSimulatedBySoftware);
    XCTAssertEqual(self.manager.location, value);
    XCTAssertEqual(self.receiver.callbackThread, NSThread.currentThread);
    XCTAssertEqual(self.manager.originalRequests, 0u);
    XCTAssertNil(self.proxy.timer);
    CLLocation *destination = [[CLLocation alloc] initWithLatitude:35 longitude:139];
    XCTAssertEqual(destination.coordinate.latitude, 35);
    XCTAssertEqual(destination.coordinate.longitude, 139);
    [self.manager requestLocation]; [self drain];
    XCTAssertEqual(self.receiver.locations.count, 2u);
}
- (void)testPendingStopCancelsAndRestartCannotResurrectOldDelivery {
    [self.manager requestLocation]; [self.manager stopUpdatingLocation]; [self drain];
    XCTAssertEqual(self.receiver.locations.count, 0u);
    [self.manager startUpdatingLocation]; [self.manager stopUpdatingLocation];
    [self.manager requestLocation]; [self drain];
    XCTAssertEqual(self.receiver.locations.count, 1u);
    XCTAssertNil(self.proxy.timer);
}
- (void)testPermissionIsPreservedAndDeniedLocationIsUnavailable {
    self.manager.authorizationStatus = kCLAuthorizationStatusNotDetermined;
    [self.manager requestWhenInUseAuthorization]; [self.manager requestLocation]; [self drain];
    XCTAssertEqual(self.manager.permissionRequests, 1u);
    XCTAssertEqual(self.receiver.locations.count, 0u); XCTAssertNil(self.receiver.error);
    self.manager.authorizationStatus = kCLAuthorizationStatusAuthorizedWhenInUse;
    [self.proxy locationManagerDidChangeAuthorization:(id)self.manager]; [self drain];
    XCTAssertEqual(self.receiver.authorizations, 1u); XCTAssertEqual(self.receiver.locations.count, 1u);
    self.manager.authorizationStatus = kCLAuthorizationStatusDenied;
    [self.manager requestLocation]; [self drain];
    XCTAssertNil(self.manager.location); XCTAssertEqual(self.receiver.error.code, kCLErrorDenied);
    XCTAssertEqual(self.receiver.locations.count, 1u); XCTAssertNil(self.proxy.timer);
    self.manager.authorizationStatus = kCLAuthorizationStatusAuthorizedAlways;
    LCTestServicesEnabled = NO;
    [self.manager requestLocation]; [self drain];
    XCTAssertNil(self.manager.location); XCTAssertEqual(self.receiver.locations.count, 1u);
}
- (void)testContinuousTimerDistanceFilterAndReentrantStop {
    [self.manager startUpdatingLocation]; [self drain];
    XCTAssertNotNil(self.proxy.timer);
    [self.proxy.timer fire];
    XCTAssertEqual(self.receiver.locations.count, 2u);
    self.manager.distanceFilter = 100; [self drain];
    XCTAssertNil(self.proxy.timer); XCTAssertEqual(self.receiver.locations.count, 2u);
    self.manager.distanceFilter = -1; [self drain];
    XCTAssertNotNil(self.proxy.timer);
    __weak LCTestLocationManager *weakManager = self.manager;
    self.receiver.onUpdate = ^{ [weakManager stopUpdatingLocation]; };
    [self.proxy.timer fire];
    XCTAssertNil(self.proxy.timer);
    NSUInteger count = self.receiver.locations.count;
    [self.proxy deliver]; XCTAssertEqual(self.receiver.locations.count, count);
}
- (void)testIndependentManagersDelegateReplacementAndNoRealSampleDelivery {
    LCTestLocationManager *other = [LCTestLocationManager new];
    LCTestLocationDelegate *otherReceiver = [LCTestLocationDelegate new]; other.delegate = otherReceiver;
    [other requestLocation]; [self.manager startUpdatingLocation]; [self drain];
    [self.manager stopUpdatingLocation];
    [other requestLocation]; [self drain];
    XCTAssertEqual(otherReceiver.locations.count, 2u); XCTAssertEqual(self.receiver.locations.count, 1u);
    [self.proxy locationManager:(id)self.manager didUpdateLocations:@[[[CLLocation alloc] initWithLatitude:1 longitude:2]]];
    XCTAssertEqual(self.receiver.locations.count, 1u);
    [self.proxy locationManager:(id)self.manager didUpdateHeading:(id)[NSObject new]];
    XCTAssertEqual(self.receiver.headings, 1u);
    [self.manager requestLocation]; self.manager.delegate = otherReceiver; [self drain];
    XCTAssertEqual(self.receiver.locations.count, 1u); XCTAssertEqual(otherReceiver.locations.count, 3u);
    other.delegate = nil;
}
- (void)testSignificantStationaryUpdatesAndLegacyDelegate {
    LCTestLegacyLocationDelegate *legacy = [LCTestLegacyLocationDelegate new]; self.manager.delegate = legacy;
    [self.proxy locationManagerDidChangeAuthorization:(id)self.manager];
    [self.manager startMonitoringSignificantLocationChanges]; [self drain];
    XCTAssertEqual(legacy.authorizations, 1u); XCTAssertEqual(legacy.updates, 1u);
    XCTAssertNil(self.proxy.timer);
    [self.proxy deliver]; XCTAssertEqual(legacy.updates, 1u);
    [self.manager stopMonitoringSignificantLocationChanges];
    [self.manager requestLocation]; [self drain]; XCTAssertEqual(legacy.updates, 2u);
}
- (void)testManagerAndDelegateAreNotRetainedByTimer {
    __weak LCTestLocationManager *weakManager;
    __weak LCTestLocationDelegate *weakDelegate;
    __weak LCLocationDelegateProxy *weakProxy;
    @autoreleasepool {
        LCTestLocationManager *manager = [LCTestLocationManager new];
        LCTestLocationDelegate *delegate = [LCTestLocationDelegate new];
        manager.delegate = delegate; [manager startUpdatingLocation]; [self drain];
        weakManager = manager; weakDelegate = delegate; weakProxy = LCProxy((id)manager);
        XCTAssertNotNil(weakProxy.timer);
    }
    XCTAssertNil(weakDelegate); XCTAssertNil(weakManager); XCTAssertNil(weakProxy);
}
- (void)testSettingsValidationAndLaunchScope {
    NSDictionary *valid = @{@"enabled": @YES, @"latitude": @0, @"longitude": @0, @"name": @"Origin"};
    XCTAssertEqualObjects(LCAppLocationSettings(valid), valid);
    for (id invalid in @[NSNull.null, @[], @"0,0", @{}, @{@"latitude": @YES, @"longitude": @0},
                            @{@"latitude": @91, @"longitude": @0}, @{@"latitude": @0, @"longitude": @181},
                            @{@"latitude": @(NAN), @"longitude": @0}, @{@"latitude": @0, @"longitude": @(INFINITY)}]) {
        XCTAssertEqual(LCAppLocationSettings(invalid).count, 0u);
    }
    NSMutableDictionary *info = [@{LCAppLocationKey: valid} mutableCopy];
    // No virtualWindow/isLiveProcess gate: normal and either multitasking path use the same launch function.
    XCTAssertTrue(LCAppLocationShouldEnable(@"game", NO, info));
    XCTAssertFalse(LCAppLocationShouldEnable(nil, NO, info));
    XCTAssertFalse(LCAppLocationShouldEnable(@"game", YES, info));
    for (NSString *disabled in @[@"dontInjectTweakLoader", @"is32bit"]) {
        info[disabled] = @YES; XCTAssertFalse(LCAppLocationShouldEnable(@"game", NO, info)); [info removeObjectForKey:disabled];
    }
    info[LCAppLocationKey] = @{@"enabled": @NO, @"latitude": @0, @"longitude": @0};
    XCTAssertFalse(LCAppLocationShouldEnable(@"game", NO, info));
    NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:
        [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL]
        options:0 format:NULL error:NULL];
    XCTAssertEqualObjects(decoded, info);
}
@end
