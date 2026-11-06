#import <XCTest/XCTest.h>
#define LCLocationUI LCTestSessionUI
#import "../LiveContainer/Tweaks/LocationSession.m"

// The session suite exercises production persistence without loading Swift UI.
@implementation LCTestSessionUI
+ (UIViewController *)pickerWithInitial:(NSDictionary *)initial completion:(void (^)(NSDictionary *))completion dismissal:(void (^)(void))dismissal { return [UIViewController new]; }
+ (void)showControlsForSession:(LCLocationSession *)session inScene:(UIWindowScene *)scene {}
+ (void)showShortcutForSession:(LCLocationSession *)session inScene:(UIWindowScene *)scene {}
+ (void)hideControlsForSession:(LCLocationSession *)session {}
+ (void)installGuestControlsForSession:(LCLocationSession *)session {}
@end

@interface LocationSessionTests : XCTestCase
@property(nonatomic) NSString *path;
@property(nonatomic) LCLocationSession *session;
@end
@implementation LocationSessionTests
- (LCLocationSession *)newSession {
    LCLocationSession *session = [LCLocationSession new];
    session.bundlePath = self.path; session.title = @"Test";
    session.identifier = NSUUID.UUID.UUIDString; session.notificationName = [@"test.location." stringByAppendingString:session.identifier];
    session.movementLock = -1; session.token = NOTIFY_TOKEN_INVALID;
    [session refresh]; return session;
}
- (void)setUp {
    [super setUp];
    self.path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:self.path withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTAssertTrue([@{@"unrelated": @"preserved"} writeToFile:[self.path stringByAppendingPathComponent:@"LCAppInfo.plist"] atomically:YES]);
    self.session = [self newSession];
}
- (void)tearDown {
    [self.session stopMoving]; self.session = nil;
    [NSFileManager.defaultManager removeItemAtPath:self.path error:nil]; [super tearDown];
}
- (NSDictionary *)point:(double)latitude {
    return @{@"latitude": @(latitude), @"longitude": @114, @"enabled": @YES, @"name": @""};
}
- (void)testPointEnableFavoritesAndUnrelatedSettingsRoundTrip {
    XCTAssertTrue([self.session selectPoint:[self point:22] enabled:YES]);
    [self.session addFavorite]; [self.session addFavorite];
    XCTAssertEqual(self.session.favorites.count, 1u);
    XCTAssertTrue([self.session setLocationEnabled:NO]);
    LCLocationSession *other = [self newSession];
    XCTAssertFalse([other.settings[@"enabled"] boolValue]);
    XCTAssertEqualObjects(other.settings[@"latitude"], @22);
    XCTAssertEqual(other.favorites.count, 1u);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:self.session.infoPath][@"unrelated"], @"preserved");
    [other removeFavoriteAtIndex:0]; [self.session refresh];
    XCTAssertEqual(self.session.favorites.count, 0u);
}
- (void)testMotionIsBoundedAndStopPersistsLatestPoint {
    [self.session selectPoint:[self point:22] enabled:YES];
    [self.session moveEast:1 north:0 speed:6];
    XCTAssertTrue(self.session.moving);
    self.session.lastTick -= 20; [self.session tick];
    double moved = [self.session.snapshot[@"longitude"] doubleValue];
    XCTAssertGreaterThan(moved, 114); XCTAssertLessThan(moved, 114.0001);
    XCTAssertEqualObjects(self.session.settings[@"longitude"], @114);
    [self.session stopMoving];
    XCTAssertFalse(self.session.moving);
    XCTAssertEqualWithAccuracy([self.session.settings[@"longitude"] doubleValue], moved, 1e-9);
    XCTAssertNil(self.session.snapshot[@"speed"]);
    [self.session moveEast:0 north:0 speed:6]; XCTAssertFalse(self.session.moving);
}
- (void)testNewerSelectionWinsBeforeTickAndBeforeStop {
    [self.session selectPoint:[self point:22] enabled:YES];
    LCLocationSession *other = [self newSession];
    [self.session moveEast:1 north:0 speed:6];
    [other selectPoint:[self point:35] enabled:YES];
    [self.session tick];
    XCTAssertFalse(self.session.moving); XCTAssertEqualObjects(self.session.snapshot[@"latitude"], @35);
    [self.session moveEast:1 north:0 speed:6];
    [other selectPoint:[self point:36] enabled:YES];
    [self.session stopMoving];
    XCTAssertEqualObjects(self.session.settings[@"latitude"], @36);
    [other refresh]; XCTAssertEqualObjects(other.settings[@"latitude"], @36);
}
- (void)testExclusiveMotionOwnershipAndFailureDoesNotReportSaved {
    [self.session selectPoint:[self point:22] enabled:YES];
    LCLocationSession *other = [self newSession];
    [self.session moveEast:1 north:0 speed:6];
    [other moveEast:0 north:1 speed:6];
    XCTAssertFalse(other.moving); XCTAssertEqualObjects(other.error, @"lc.location.otherController");
    [self.session stopMoving]; [other moveEast:0 north:1 speed:6];
    XCTAssertTrue(other.moving); [other stopMoving];
    int descriptor = open([self.path stringByAppendingPathComponent:@".lc-location-settings.lock"].fileSystemRepresentation, O_RDWR);
    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0);
    XCTAssertFalse([self.session selectPoint:[self point:40] enabled:YES]);
    XCTAssertEqualObjects(self.session.error, @"lc.location.saveFailed");
    flock(descriptor, LOCK_UN); close(descriptor);
    [self.session refresh]; XCTAssertNotEqualObjects(self.session.settings[@"latitude"], @40);
}
@end
