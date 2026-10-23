#import <XCTest/XCTest.h>
#import "../MultitaskSupport/TapSyncCoordinator.h"
#import "../MultitaskSupport/TapSyncSession.h"
#import "../MultitaskSupport/TapSyncRecovery.h"
#import "../LiveContainer/utils.h"

// Supply an isolated defaults suite when compiling the production coordinator in
// the small UIKit test host. No guest containers or application preferences exist here.
@implementation NSUserDefaults (LCTapSyncTestDefaults)
+ (instancetype)lcSharedDefaults {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.livecontainer.tests.sync-recovery"]; });
    return defaults;
}
+ (bool)isLiveProcess { return false; }
@end

@interface LCTapSyncCoordinator (RecoveryTests)
- (BOOL)hostIsAnimatingRotation;
- (void)hostWillResignActive:(NSNotification *)notification;
@end

// Test only the UIKit rotation-transition signal; geometry validation, temporary
// suspension, preparation and all recovery callbacks run through the real coordinator.
@interface LCTestSyncCoordinator : LCTapSyncCoordinator
@property(nonatomic) BOOL animatingRotation;
@end
@implementation LCTestSyncCoordinator
- (BOOL)hostIsAnimatingRotation { return self.animatingRotation || [super hostIsAnimatingRotation]; }
@end

@interface LCTestSyncPeer : NSObject
@property(nonatomic) BOOL ready, canReplay, touching, suspended, resumeOnSource, holdSuspension;
@property(nonatomic) uint64_t revision;
@property(nonatomic) NSUInteger prepares, suspensions, stops, replays;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, copy) void (^stateDidChange)(void);
@property(nonatomic, copy) void (^didReceiveTap)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didReceiveTouch)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didReceiveTouchFrame)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didInterrupt)(NSString *, LCTapSyncResult);
@property(nonatomic, copy) void (^didChangePhysicalInput)(NSString *, uint64_t, BOOL, BOOL, NSTimeInterval);
@property(nonatomic, copy) void (^pendingSuspension)(LCTapSyncResult, BOOL, uint64_t);
@end
@implementation LCTestSyncPeer
- (BOOL)isReady { return self.ready; }
- (instancetype)init {
    if ((self = [super init])) { _ready = YES; _canReplay = YES; }
    return self;
}
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode resumeOnSource:(BOOL)resumeOnSource
                 reply:(void (^)(LCTapSyncResult))reply {
    self.prepares++;
    if (self.touching) { reply(LCTapSyncResultPhysicalTouch); return; }
    self.session = session;
    self.suspended = NO;
    self.resumeOnSource = resumeOnSource;
    self.revision = 0;
    reply(LCTapSyncResultAccepted);
}
- (void)suspendSession:(NSString *)session reply:(void (^)(LCTapSyncResult, BOOL, uint64_t))reply {
    self.suspensions++;
    self.suspended = YES;
    if (self.holdSuspension) self.pendingSuspension = reply;
    else reply([self.session isEqual:session] ? LCTapSyncResultAccepted : LCTapSyncResultStopped, self.touching, self.revision);
}
- (void)stopSession:(NSString *)session {
    if (![self.session isEqual:session]) return;
    self.stops++;
    self.session = nil;
    self.suspended = NO;
}
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence reply:(void (^)(LCTapSyncResult))reply {
    self.replays++;
    reply(LCTapSyncResultAccepted);
}
- (void)inputTouching:(BOOL)touching began:(BOOL)began {
    self.touching = touching;
    if (self.didChangePhysicalInput) self.didChangePhysicalInput(self.session, ++self.revision, touching, began,
                                                               NSProcessInfo.processInfo.systemUptime);
}
@end

@interface LCTestSyncGuest : NSObject
@property(nonatomic, copy) NSString *dataUUID, *bundleId;
@property(nonatomic) UIView *view;
@property(nonatomic) LCTestSyncPeer *tapSyncPeer;
@end
@implementation LCTestSyncGuest
- (BOOL)usesHostingControllerAPI { return NO; }
@end

@interface LCTestSyncWindow : NSObject
@property(nonatomic) UIView *view;
@property(nonatomic) LCTestSyncGuest *appSceneVC;
@property(nonatomic) CGFloat scaleRatio;
@end
@implementation LCTestSyncWindow
@end

@interface LCTestSyncHost : UIView
@property(nonatomic, copy) NSArray<LCTestSyncWindow *> *tapSyncWindows;
@end
@implementation LCTestSyncHost
- (BOOL)isAdjustingGridDividers { return NO; }
- (BOOL)isChoosingGridSwap { return NO; }
- (LCTestSyncWindow *)windowForContainer:(NSString *)container {
    for (LCTestSyncWindow *window in self.tapSyncWindows) if ([window.appSceneVC.dataUUID isEqual:container]) return window;
    return nil;
}
@end

@interface TapSyncCoordinatorTests : XCTestCase
@property(nonatomic) LCTestSyncCoordinator *sync;
@property(nonatomic) LCTestSyncHost *host;
@property(nonatomic) UIWindow *window;
@property(nonatomic, copy) NSArray<LCTestSyncPeer *> *peers;
@end
@implementation TapSyncCoordinatorTests
- (void)setUp {
    [super setUp];
    [NSUserDefaults.lcSharedDefaults removePersistentDomainForName:@"com.livecontainer.tests.sync-recovery"];
    self.sync = [LCTestSyncCoordinator new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            break;
        }
    }
    XCTAssertNotNil(self.window);
    self.window.frame = CGRectMake(0, 0, 1024, 768);
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    self.host = [[LCTestSyncHost alloc] initWithFrame:self.window.bounds];
    [self.window.rootViewController.view addSubview:self.host];
    NSMutableArray *windows = [NSMutableArray array], *peers = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSString *container in @[@"A", @"B", @"C", @"D"]) {
        LCTestSyncWindow *window = [LCTestSyncWindow new];
        window.scaleRatio = 1;
        window.view = [[UIView alloc] initWithFrame:CGRectMake(10 + 250 * index++, 20, 200, 400)];
        window.appSceneVC = [LCTestSyncGuest new];
        window.appSceneVC.dataUUID = container;
        window.appSceneVC.bundleId = @"test.app";
        window.appSceneVC.view = [[UIView alloc] initWithFrame:window.view.bounds];
        window.appSceneVC.tapSyncPeer = [LCTestSyncPeer new];
        [window.view addSubview:window.appSceneVC.view];
        [self.host addSubview:window.view];
        [windows addObject:window];
        [peers addObject:window.appSceneVC.tapSyncPeer];
        [self.sync registerScene:(id)window.appSceneVC];
    }
    self.peers = peers.copy;
    self.host.tapSyncWindows = windows.copy;
    self.sync.host = (id)self.host;
    [self.sync selectSource:@"A" targets:@[@"B", @"C", @"D"]];
    XCTAssertTrue(self.sync.canStart);
}
- (void)tearDown {
    [self.sync pause];
    self.window.hidden = YES;
    self.window.windowScene = nil;
    self.window.rootViewController = nil;
    self.host = nil;
    self.window = nil;
    self.peers = nil;
    self.sync = nil;
    [super tearDown];
}
- (void)waitUntil:(BOOL (^)(void))condition {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return condition(); }];
    [self waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil]] timeout:2];
}
- (void)letRecoveryCheckFinish {
    XCTestExpectation *delay = [self expectationWithDescription:@"pending recovery check"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [delay fulfill]; });
    [self waitForExpectations:@[delay] timeout:2];
}
- (void)testFollowerPausesEveryAccountAndSourceResumesFreshSession {
    self.sync.resumeOnSource = YES;
    [self.sync start];
    XCTAssertTrue(self.sync.active);
    NSString *oldSession = self.peers[0].session;
    NSDictionary *tap = LCTapSyncEncode((LCTapSyncSample){0.5, 0.5, 200, 400, NSProcessInfo.processInfo.systemUptime, 0.05, 1, 1});
    self.peers[0].didReceiveTap(tap, oldSession, 1);
    XCTAssertEqual(self.sync.forwardedTapCount, 1u);
    [self.peers[1] inputTouching:YES began:YES];
    XCTAssertFalse(self.sync.active);
    XCTAssertTrue(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.waitingForSource");
    for (LCTestSyncPeer *peer in self.peers) { XCTAssertEqual(peer.suspensions, 1u); XCTAssertTrue(peer.suspended); }
    self.peers[0].didReceiveTap(tap, oldSession, 2);
    for (NSUInteger i = 1; i < 4; i++) XCTAssertEqual(self.peers[i].replays, 1u);
    [self.peers[1] inputTouching:NO began:NO];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active); // Finishing follower input alone is insufficient.
    [self.peers[0] inputTouching:YES began:YES];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active); // The return gesture stays local until released.
    [self.peers[0] inputTouching:NO began:NO];
    [self waitUntil:^BOOL { return self.sync.active; }];
    XCTAssertFalse(self.sync.recovering);
    XCTAssertNotEqualObjects(self.peers[0].session, oldSession);
    XCTAssertEqual(self.sync.forwardedTapCount, 1u);
    for (LCTestSyncPeer *peer in self.peers) { XCTAssertEqual(peer.prepares, 2u); XCTAssertEqual(peer.stops, 1u); }
    self.peers[1].didInterrupt(oldSession, LCTapSyncResultKeyboardVisible);
    self.peers[0].didReceiveTap(tap, oldSession, 3);
    XCTAssertTrue(self.sync.active);
}
- (void)testPendingAcknowledgmentAndOtherHeldFollowerBlockResume {
    self.sync.resumeOnSource = YES;
    [self.sync start];
    self.peers[3].holdSuspension = YES;
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[2] inputTouching:YES began:YES];
    [self.peers[0] inputTouching:YES began:YES];
    [self.peers[0] inputTouching:NO began:NO];
    [self.peers[1] inputTouching:NO began:NO];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active);
    self.peers[3].pendingSuspension(LCTapSyncResultAccepted, NO, 0);
    self.peers[3].pendingSuspension = nil;
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active);
    [self.peers[2] inputTouching:NO began:NO];
    [self waitUntil:^BOOL { return self.sync.active; }];
}
- (void)testManualPauseAndLateReplyCannotRestart {
    self.sync.resumeOnSource = YES;
    [self.sync start];
    NSString *session = self.peers[0].session;
    self.peers[3].holdSuspension = YES;
    [self.peers[1] inputTouching:YES began:YES];
    [self.sync pause];
    self.peers[3].pendingSuspension(LCTapSyncResultAccepted, NO, 0);
    self.peers[0].didChangePhysicalInput(session, 1, YES, YES, NSProcessInfo.processInfo.systemUptime);
    self.peers[0].didChangePhysicalInput(session, 2, NO, NO, NSProcessInfo.processInfo.systemUptime);
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active);
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.paused");
}
- (void)testRotationWaitsForTransitionAndIgnoresAdditionalGeometryInterrupts {
    self.sync.autoResumeAfterRotation = YES;
    [self.sync start];
    NSString *session = self.peers[0].session;
    self.sync.animatingRotation = YES;
    self.host.tapSyncWindows[0].view.frame = CGRectOffset(self.host.tapSyncWindows[0].view.frame, 0, 2);
    [self.sync validateWindows];
    XCTAssertTrue(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.waitingForRotation");
    self.peers[1].didInterrupt(session, LCTapSyncResultGeometryChanged);
    [self letRecoveryCheckFinish];
    XCTAssertTrue(self.sync.recovering);
    XCTAssertFalse(self.sync.active);
    self.sync.animatingRotation = NO;
    [self.sync validateWindows];
    [self waitUntil:^BOOL { return self.sync.active; }];
    XCTAssertNotEqualObjects(self.peers[0].session, session);
}
- (void)testRotationOptionDoesNotResumeOrdinaryResize {
    self.sync.autoResumeAfterRotation = YES;
    [self.sync start];
    self.host.tapSyncWindows[0].view.frame = CGRectOffset(self.host.tapSyncWindows[0].view.frame, 0, 2);
    [self.sync validateWindows];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active);
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.layoutChanged");
}
- (void)testRotationFollowerInputRequiresSourceReturn {
    self.sync.resumeOnSource = YES;
    self.sync.autoResumeAfterRotation = YES;
    [self.sync start];
    self.sync.animatingRotation = YES;
    self.host.tapSyncWindows[0].view.frame = CGRectOffset(self.host.tapSyncWindows[0].view.frame, 0, 2);
    [self.sync validateWindows];
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[1] inputTouching:NO began:NO];
    self.sync.animatingRotation = NO;
    [self.sync validateWindows];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.waitingForSource");
    [self.peers[0] inputTouching:YES began:YES];
    [self.peers[0] inputTouching:NO began:NO];
    [self waitUntil:^BOOL { return self.sync.active; }];
}
- (void)testKeyboardBackgroundAndDisconnectedGuestCancelRecovery {
    self.sync.resumeOnSource = YES;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    self.peers[1].didInterrupt(self.peers[1].session, LCTapSyncResultKeyboardVisible);
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.keyboardVisible");
    self.peers[1].touching = NO;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    [self.sync hostWillResignActive:nil];
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
    self.peers[1].touching = NO;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    self.peers[2].ready = NO;
    self.peers[2].stateDidChange();
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.unavailable");
}
- (void)testOptionsPersistWithoutRestoringActiveRecovery {
    XCTAssertFalse(self.sync.resumeOnSource);
    XCTAssertFalse(self.sync.autoResumeAfterRotation);
    self.sync.resumeOnSource = YES;
    self.sync.autoResumeAfterRotation = YES;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    XCTAssertTrue(self.sync.recovering);
    LCTapSyncCoordinator *restored = [LCTapSyncCoordinator new];
    XCTAssertTrue(restored.resumeOnSource);
    XCTAssertTrue(restored.autoResumeAfterRotation);
    XCTAssertFalse(restored.active || restored.starting || restored.recovering);
    XCTAssertEqualObjects(restored.sourceContainer, @"A");
    XCTAssertEqualObjects(restored.targetContainers, (@[@"B", @"C", @"D"]));
    self.sync.resumeOnSource = NO;
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.paused");
}
@end
