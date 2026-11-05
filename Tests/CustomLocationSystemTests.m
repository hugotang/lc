#import <XCTest/XCTest.h>
// Compile the same hook in isolation so the real-manager check does not
// replace the globals used by the deterministic lifecycle suite.
#define LCLocationDelegateProxy LCTestSystemLocationProxy
#define LCCustomLocationInstall LCTestSystemLocationInstall
#import "../LiveContainer/Tweaks/CustomLocation.m"

@interface LCTestSystemLocationManager : CLLocationManager
@end
@implementation LCTestSystemLocationManager
// Only authorization is controlled. Initialization, delegate storage, distance
// filter and runtime method dispatch are provided by Core Location itself.
+ (BOOL)locationServicesEnabled { return YES; }
- (CLAuthorizationStatus)authorizationStatus { return kCLAuthorizationStatusAuthorizedWhenInUse; }
@end

@interface CustomLocationSystemTests : XCTestCase <CLLocationManagerDelegate>
@property(nonatomic, strong) XCTestExpectation *update;
@property(nonatomic, strong) CLLocation *received;
@end
@implementation CustomLocationSystemTests
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    self.received = locations.lastObject;
    [self.update fulfill];
    self.update = nil;
}
- (void)testRealManagerInitializationDelegateStorageAndOneShot {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ XCTAssertTrue(LCCustomLocationHookClass(LCTestSystemLocationManager.class)); });
    LCCustomCoordinate = CLLocationCoordinate2DMake(-33.8688, 151.2093);
    @autoreleasepool {
        LCTestSystemLocationManager *manager = [LCTestSystemLocationManager new];
        manager.delegate = self;
        XCTAssertEqual(manager.delegate, self);
        XCTAssertEqual(LCOriginalLocationDelegate(manager, @selector(delegate)), LCProxy(manager));
        self.update = [self expectationWithDescription:@"actual CLLocationManager request"];
        [manager requestLocation];
        [self waitForExpectations:@[self.update] timeout:5];
        XCTAssertNotNil(self.received);
        XCTAssertEqualWithAccuracy(self.received.coordinate.latitude, -33.8688, 0.000001);
        XCTAssertEqualWithAccuracy(self.received.coordinate.longitude, 151.2093, 0.000001);
        XCTAssertEqual(manager.location, self.received);
        XCTAssertTrue(self.received.sourceInformation.isSimulatedBySoftware);
        [manager stopUpdatingLocation];
        manager.delegate = nil;
        XCTAssertNil(manager.delegate);
    }
}
@end
