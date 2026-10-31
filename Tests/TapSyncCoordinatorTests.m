#import <XCTest/XCTest.h>
#import "../MultitaskSupport/TapSyncCoordinator.h"
#import "../MultitaskSupport/TapSyncSession.h"
#import "../MultitaskSupport/TapSyncRecovery.h"
#import "../LiveContainer/utils.h"
#import "TapSyncTestWindow.h"

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
- (NSArray *)currentGeometry;
- (NSArray *)currentGeometryWithProblem:(NSString * __autoreleasing *)problem;
- (BOOL)hostIsAnimatingRotation;
- (BOOL)hostIsForegroundActive;
- (BOOL)hostHasLostForeground;
- (void)hostWillResignActive:(NSNotification *)notification;
- (void)hostDidEnterBackground:(NSNotification *)notification;
- (void)hostDidBecomeActive:(NSNotification *)notification;
- (void)hostSceneWillDeactivate:(NSNotification *)notification;
- (void)hostSceneDidEnterBackground:(NSNotification *)notification;
- (void)hostSceneDidActivate:(NSNotification *)notification;
@end

// Control only rotation/activation signals. Geometry validation, suspension,
// preparation and all recovery callbacks run through the production coordinator.
@interface LCTestSyncCoordinator : LCTapSyncCoordinator
@property(nonatomic) BOOL animatingRotation;
@property(nonatomic) BOOL reportsHostInactive;
@property(nonatomic) BOOL reportsActivationPending;
@end
@implementation LCTestSyncCoordinator
- (BOOL)hostIsAnimatingRotation { return self.animatingRotation || [super hostIsAnimatingRotation]; }
- (BOOL)hostIsForegroundActive { return !self.reportsActivationPending && [super hostIsForegroundActive]; }
- (BOOL)hostHasLostForeground { return self.reportsHostInactive || [super hostHasLostForeground]; }
@end

@interface LCTestSyncPeer : NSObject
@property(nonatomic) BOOL ready, canReplay, touching, suspended, resumeOnSource, holdSuspension;
@property(nonatomic) BOOL syncReturnGesture, holdPreparation;
@property(nonatomic) BOOL holdSourceReply, holdReturnPayload;
@property(nonatomic) BOOL holdReplay;
@property(nonatomic) LCTapSyncResult preparationResult;
@property(nonatomic) uint64_t revision;
@property(nonatomic) uint64_t returnRevision;
@property(nonatomic) NSUInteger prepares, suspensions, stops, replays, sourceResumes, returnDiscards;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, copy) void (^stateDidChange)(void);
@property(nonatomic, copy) void (^didReceiveTap)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didReceiveTouch)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didReceiveTouchFrame)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy) void (^didReceiveSourceReturn)(NSArray<NSDictionary *> *, NSString *);
@property(nonatomic, copy) void (^didInterrupt)(NSString *, LCTapSyncResult);
@property(nonatomic, copy) void (^didChangePhysicalInput)(NSString *, uint64_t, BOOL, BOOL, NSTimeInterval, uint64_t);
@property(nonatomic, copy) void (^pendingSuspension)(LCTapSyncResult, BOOL, uint64_t);
@property(nonatomic, copy) void (^pendingPreparation)(LCTapSyncResult);
@property(nonatomic, copy) void (^pendingSourceReply)(LCTapSyncResult);
@property(nonatomic, copy) void (^pendingReplay)(LCTapSyncResult);
@property(nonatomic, copy) NSArray<NSDictionary *> *returnPackets;
@property(nonatomic) BOOL holdDiagnostics;
@property(nonatomic) NSUInteger diagnosticReads;
@property(nonatomic, copy) NSString *diagnosticSession;
@property(nonatomic, copy) NSDictionary *inputFailure;
@property(nonatomic, copy) void (^pendingDiagnostics)(NSDictionary *);
@end
@implementation LCTestSyncPeer
- (BOOL)isReady { return self.ready; }
- (instancetype)init {
    if ((self = [super init])) { _ready = YES; _canReplay = YES; }
    return self;
}
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode resumeOnSource:(BOOL)resumeOnSource
         syncReturnGesture:(BOOL)syncReturnGesture
                 reply:(void (^)(LCTapSyncResult))reply {
    self.prepares++;
    if (self.preparationResult != LCTapSyncResultAccepted) { reply(self.preparationResult); return; }
    if (self.touching) { reply(LCTapSyncResultPhysicalTouch); return; }
    self.session = session;
    self.suspended = NO;
    self.resumeOnSource = resumeOnSource;
    self.syncReturnGesture = syncReturnGesture;
    self.revision = 0;
    if (self.holdPreparation) self.pendingPreparation = reply;
    else reply(LCTapSyncResultAccepted);
}
- (void)resumeSourceSession:(NSString *)session previousSession:(NSString *)previous inputRevision:(uint64_t)revision
                      reply:(void (^)(LCTapSyncResult))reply {
    self.sourceResumes++;
    if (![self.session isEqualToString:previous] || !self.suspended || !self.returnRevision || self.returnRevision != revision) {
        reply(LCTapSyncResultInvalidGesture); return;
    }
    self.session = session;
    self.revision = 0;
    self.suspended = NO;
    if (!self.holdReturnPayload) self.didReceiveSourceReturn(self.returnPackets ?: @[], session);
    if (self.holdSourceReply) self.pendingSourceReply = reply;
    else reply(LCTapSyncResultAccepted);
}
- (void)discardSourceReturn:(NSString *)session beforeTime:(NSTimeInterval)time { self.returnDiscards++; }
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
    if (self.holdReplay) self.pendingReplay = reply;
    else reply(LCTapSyncResultAccepted);
}
- (void)inputTouching:(BOOL)touching began:(BOOL)began {
    self.touching = touching;
    if (began && self.syncReturnGesture) self.returnRevision = self.revision + 1;
    if (self.didChangePhysicalInput) self.didChangePhysicalInput(self.session, ++self.revision, touching, began,
                                                               NSProcessInfo.processInfo.systemUptime, self.returnRevision);
}
- (void)readInputDiagnosticsForSession:(NSString *)session reply:(void (^)(NSDictionary *))reply {
    self.diagnosticReads++;
    self.diagnosticSession = session;
    if (self.holdDiagnostics) self.pendingDiagnostics = reply;
    else reply(self.inputFailure ? @{@"lastInputFailure": self.inputFailure} : @{});
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
- (void)waitUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout;
@end
@implementation TapSyncCoordinatorTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    [NSUserDefaults.lcSharedDefaults removePersistentDomainForName:@"com.livecontainer.tests.sync-recovery"];
    self.sync = [LCTestSyncCoordinator new];
    self.window = LCTapSyncTestHostWindow();
    XCTAssertNotNil(self.window);
    self.host = [[LCTestSyncHost alloc] initWithFrame:self.window.bounds];
    self.host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
    // UIKit completes appearance and safe-area layout asynchronously. Let the
    // real scene settle before start records its strict geometry snapshot.
    [self letRecoveryCheckFinish];
    [self.window layoutIfNeeded];
    // The minimal host can run in an iPad compatibility-sized scene. Fit all
    // four accounts to its actual bounds instead of assuming a 1024-point width.
    CGFloat width = floor((self.host.bounds.size.width - 50) / 4);
    CGFloat height = MIN(2 * width, self.host.bounds.size.height - 40);
    index = 0;
    for (LCTestSyncWindow *window in self.host.tapSyncWindows) {
        window.view.frame = CGRectMake(10 + (width + 10) * index++, 20, width, height);
        window.appSceneVC.view.frame = window.view.bounds;
    }
    [self.sync selectSource:@"A" targets:@[@"B", @"C", @"D"]];
    NSString *problem;
    XCTAssertNotNil([self.sync currentGeometryWithProblem:&problem], @"host=%@, window=%@, scene=%@, problem=%@",
                    NSStringFromCGRect(self.host.bounds), NSStringFromCGRect(self.window.bounds),
                    self.window.windowScene, problem);
    XCTAssertTrue(self.sync.canStart);
}
- (void)tearDown {
    [self.sync pause];
    [self.host removeFromSuperview];
    self.host = nil;
    self.window = nil;
    self.peers = nil;
    self.sync = nil;
    [super tearDown];
}
- (void)waitUntil:(BOOL (^)(void))condition {
    [self waitUntil:condition timeout:2];
}
- (void)waitUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return condition(); }];
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil]] timeout:timeout];
    XCTAssertEqual(result, XCTWaiterResultCompleted, @"status=%@, recovering=%d, ready=%d, geometry=%@, initial=%@",
                   self.sync.statusKey, self.sync.recovering, [[self.sync valueForKey:@"recovery"] canResume],
                   self.sync.currentGeometry, [self.sync valueForKey:@"geometry"]);
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
    CGSize size = self.host.tapSyncWindows[0].appSceneVC.view.bounds.size;
    NSDictionary *tap = LCTapSyncEncode((LCTapSyncSample){0.5, 0.5, size.width, size.height, NSProcessInfo.processInfo.systemUptime, 0.05, 1, 1});
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
    self.peers[0].didChangePhysicalInput(session, 1, YES, YES, NSProcessInfo.processInfo.systemUptime, 0);
    self.peers[0].didChangePhysicalInput(session, 2, NO, NO, NSProcessInfo.processInfo.systemUptime, 0);
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
    [self.sync hostDidBecomeActive:nil];
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
    XCTAssertFalse(self.sync.syncReturnGesture);
    self.sync.resumeOnSource = YES;
    self.sync.autoResumeAfterRotation = YES;
    self.sync.syncReturnGesture = YES;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    XCTAssertTrue(self.sync.recovering);
    LCTapSyncCoordinator *restored = [LCTapSyncCoordinator new];
    XCTAssertTrue(restored.resumeOnSource);
    XCTAssertTrue(restored.autoResumeAfterRotation);
    XCTAssertTrue(restored.syncReturnGesture);
    XCTAssertFalse(restored.active || restored.starting || restored.recovering);
    XCTAssertEqualObjects(restored.sourceContainer, @"A");
    XCTAssertEqualObjects(restored.targetContainers, (@[@"B", @"C", @"D"]));
    self.sync.resumeOnSource = NO;
    XCTAssertFalse(self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.paused");
}
- (void)testReturnGestureOptionResumesBeforeSourceFingerLifts {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    [self.sync start];
    NSString *previous = self.peers[0].session;
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[1] inputTouching:NO began:NO];
    [self.peers[0] inputTouching:YES began:YES];
    XCTAssertTrue(self.sync.active);
    XCTAssertTrue(self.peers[0].touching);
    XCTAssertEqual(self.peers[0].sourceResumes, 1u);
    XCTAssertEqual(self.peers[0].prepares, 1u);
    XCTAssertNotEqualObjects(self.peers[0].session, previous);
    for (NSUInteger i = 1; i < 4; i++) XCTAssertEqual(self.peers[i].prepares, 2u);
}
- (void)testFirstReturnWaitsForOtherFollowerAndCancellationReply {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    [self.sync start];
    self.peers[3].holdSuspension = YES;
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[2] inputTouching:YES began:YES];
    [self.peers[0] inputTouching:YES began:YES];
    [self.peers[1] inputTouching:NO began:NO];
    self.peers[3].pendingSuspension(LCTapSyncResultAccepted, NO, 0);
    XCTAssertFalse(self.sync.active);
    [self.peers[2] inputTouching:NO began:NO];
    XCTAssertTrue(self.sync.active);
    XCTAssertTrue(self.peers[0].touching);
}
- (void)testManualPauseWhileFollowersPrepareDropsFirstReturn {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[1] inputTouching:NO began:NO];
    self.peers[3].holdPreparation = YES;
    [self.peers[0] inputTouching:YES began:YES];
    XCTAssertTrue(self.sync.starting);
    [self.sync pause];
    self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
    XCTAssertFalse(self.sync.active || self.sync.recovering || self.sync.starting);
    XCTAssertNil(self.peers[0].session);
    XCTAssertEqual(self.peers[0].sourceResumes, 0u);
}
- (void)testReturningTapCanFinishDuringFollowerPreparation {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    [self.sync start];
    [self.peers[1] inputTouching:YES began:YES];
    [self.peers[1] inputTouching:NO began:NO];
    self.peers[3].holdPreparation = YES;
    [self.peers[0] inputTouching:YES began:YES];
    XCTAssertTrue(self.sync.starting);
    [self.peers[0] inputTouching:NO began:NO];
    self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
    XCTAssertTrue(self.sync.active);
    XCTAssertEqual(self.peers[0].sourceResumes, 1u);
}
- (void)testFirstReturnWaitsForPayloadAndSourceReplyInEitherOrder {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    for (NSNumber *payloadFirst in @[@YES, @NO]) {
        [self.sync start];
        XCTAssertTrue(self.sync.active);
        [self.peers[1] inputTouching:YES began:YES];
        [self.peers[1] inputTouching:NO began:NO];
        CGSize size = self.host.tapSyncWindows[0].appSceneVC.view.bounds.size;
        NSDictionary *tap = LCTapSyncEncode((LCTapSyncSample){0.5, 0.5, size.width, size.height,
                                             NSProcessInfo.processInfo.systemUptime, 0.05, 1, 1});
        self.peers[0].returnPackets = @[@{@"tap": tap}];
        self.peers[0].holdReturnPayload = YES;
        self.peers[0].holdSourceReply = YES;
        [self.peers[0] inputTouching:YES began:YES];
        XCTAssertTrue(self.sync.starting);
        NSUInteger replays = self.peers[1].replays;
        if (payloadFirst.boolValue) self.peers[0].didReceiveSourceReturn(self.peers[0].returnPackets, self.peers[0].session);
        else self.peers[0].pendingSourceReply(LCTapSyncResultAccepted);
        XCTAssertTrue(self.sync.starting);
        XCTAssertFalse(self.sync.active);
        XCTAssertEqual(self.peers[1].replays, replays);
        if (payloadFirst.boolValue) self.peers[0].pendingSourceReply(LCTapSyncResultAccepted);
        else self.peers[0].didReceiveSourceReturn(self.peers[0].returnPackets, self.peers[0].session);
        XCTAssertTrue(self.sync.active);
        XCTAssertEqual(self.peers[1].replays, replays + 1);
        [self.sync pause];
        self.peers[0].touching = NO;
        self.peers[0].holdReturnPayload = NO;
        self.peers[0].holdSourceReply = NO;
        self.peers[0].pendingSourceReply = nil;
    }
}
- (void)testFirstReturnCancellationAndNewFollowerInputDuringPreparation {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    for (NSNumber *newFollower in @[@YES, @NO]) {
        [self.sync start];
        [self.peers[1] inputTouching:YES began:YES];
        [self.peers[1] inputTouching:NO began:NO];
        NSString *oldSession = self.peers[0].session;
        self.peers[3].holdPreparation = YES;
        [self.peers[0] inputTouching:YES began:YES];
        XCTAssertTrue(self.sync.starting);
        // A delayed token-clearing notification from before this source begin
        // must not cancel its newer return gesture.
        self.peers[0].didChangePhysicalInput(oldSession, 0, NO, NO, NSProcessInfo.processInfo.systemUptime, 0);
        XCTAssertTrue(self.sync.starting);
        if (newFollower.boolValue) {
            self.peers[3].didChangePhysicalInput(oldSession, 99, YES, YES, NSProcessInfo.processInfo.systemUptime + 0.01, 0);
            XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.physicalTouch");
        } else {
            self.peers[0].didChangePhysicalInput(oldSession, 99, YES, NO, NSProcessInfo.processInfo.systemUptime, 0);
            XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.gestureInterrupted");
        }
        self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        XCTAssertNil(self.peers[0].session);
        self.peers[0].touching = NO;
        self.peers[3].holdPreparation = NO;
        self.peers[3].pendingPreparation = nil;
    }
}
- (NSDictionary *)freshTap {
    CGSize size = self.host.tapSyncWindows[0].appSceneVC.view.bounds.size;
    return LCTapSyncEncode((LCTapSyncSample){0.5, 0.5, size.width, size.height,
                                           NSProcessInfo.processInfo.systemUptime, 0.05, 1, 1});
}
- (void)testDelayedAcknowledgmentAfterOneSecondKeepsDeliveredInputActive {
    self.peers[3].holdReplay = YES;
    [self.sync start];
    self.peers[0].didReceiveTap(self.freshTap, self.peers[0].session, 1);
    XCTestExpectation *reply = [self expectationWithDescription:@"late acknowledgment for already delivered input"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        XCTAssertTrue(self.sync.active);
        self.peers[3].pendingReplay(LCTapSyncResultAccepted);
        self.peers[3].pendingReplay = nil;
        [reply fulfill];
    });
    [self waitForExpectations:@[reply] timeout:3];
    XCTAssertTrue(self.sync.active);
    XCTAssertEqual(self.sync.forwardedTapCount, 1u);
}
- (void)testReplyTimeoutAttributesOnlyOutstandingWindowAndLateReplyCannotRestart {
    self.peers[3].holdReplay = YES;
    [self.sync start];
    NSString *session = self.peers[0].session;
    self.peers[0].didReceiveTap(self.freshTap, session, 1);
    [self waitUntil:^BOOL { return !self.sync.active; } timeout:5];
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.tooSlow");
    XCTAssertEqualObjects(self.sync.interruptedContainers, (@[@"D"]));
    for (LCTestSyncPeer *peer in self.peers) XCTAssertNil(peer.session);
    self.peers[3].pendingReplay(LCTapSyncResultAccepted);
    self.peers[0].didReceiveTap(self.freshTap, session, 2);
    [self.sync hostDidEnterBackground:nil];
    [self.sync hostDidBecomeActive:nil];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.tooSlow");
}
- (void)testExpiredGuestReplyAndQueuedInputAreSeparateFromReplyTimeout {
    [self.sync start];
    self.peers[3].holdReplay = YES;
    self.peers[0].didReceiveTap(self.freshTap, self.peers[0].session, 1);
    self.peers[3].pendingReplay(LCTapSyncResultExpired);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.expiredInput");
    XCTAssertEqualObjects(self.sync.interruptedContainers, (@[@"D"]));
    [self.sync start];
    self.peers[0].didReceiveTap(self.freshTap, self.peers[0].session, 1);
    self.peers[0].didReceiveTap(self.freshTap, self.peers[0].session, 2);
    [self letRecoveryCheckFinish];
    [self letRecoveryCheckFinish];
    self.peers[3].pendingReplay(LCTapSyncResultAccepted);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.expiredInput");
    XCTAssertFalse(self.sync.active);
    // Only the first command reached any follower. The expired queue was dropped.
    for (NSUInteger i = 1; i < 4; i++) XCTAssertEqual(self.peers[i].replays, 2u);
    __block NSDictionary *report;
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { report = value; }];
    XCTAssertEqualObjects(report[@"lastInterruption"][@"hostInputFailure"][@"stage"], @"hostQueue");
    XCTAssertEqualObjects(report[@"lastInterruption"][@"hostInputFailure"][@"reason"], @"inputTooOld");
    XCTAssertEqualObjects(report[@"lastInterruption"][@"hostInputFailure"][@"sequenceCheck"], @"alreadyAccepted");
}
- (void)testInputDiagnosticsFreezeFailureAndDoNotChangeResumedSession {
    [self.sync start];
    NSString *failedSession = self.peers[0].session;
    self.peers[2].holdReplay = YES;
    self.peers[2].inputFailure = @{@"reason": @"inputTooOld", @"stage": @"guestReceive", @"mode": @"tapsOnly",
        @"inputAgeMs": @900, @"receivedSequence": @1, @"expectedSequence": @1,
        @"rawPacket": @"do-not-export", @"account": @"private-account", @"x": @0.5};
    self.peers[0].didReceiveTap(self.freshTap, failedSession, 1);
    self.peers[2].pendingReplay(LCTapSyncResultExpired);
    XCTAssertFalse(self.sync.active);
    self.peers[2].holdReplay = NO;
    self.peers[2].pendingReplay = nil;
    [self.sync start];
    NSString *resumedSession = self.peers[0].session;
    XCTAssertNotEqualObjects(resumedSession, failedSession);
    __block NSDictionary *report;
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { report = value; }];
    XCTAssertTrue(self.sync.active);
    XCTAssertEqualObjects(self.peers[0].session, resumedSession);
    XCTAssertEqualObjects(report[@"currentStatus"], @"lc.tapSync.active");
    XCTAssertEqualObjects(report[@"lastInterruption"][@"status"], @"lc.tapSync.expiredInput");
    XCTAssertEqualObjects(report[@"lastInterruption"][@"affectedWindows"], (@[@3]));
    XCTAssertEqualObjects(report[@"guests"][2][@"lastInputFailure"][@"reason"], @"inputTooOld");
    XCTAssertEqualObjects(report[@"guests"][2][@"windowNumber"], @3);
    for (LCTestSyncPeer *peer in self.peers) XCTAssertEqualObjects(peer.diagnosticSession, failedSession);
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] encoding:NSUTF8StringEncoding];
    XCTAssertFalse([json containsString:@"do-not-export"] || [json containsString:@"private-account"] || [json containsString:failedSession]);
    [self.sync pause];
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { report = value; }];
    XCTAssertEqualObjects(report[@"lastInterruption"][@"status"], @"lc.tapSync.expiredInput");
    [self.sync selectSource:@"A" targets:@[@"B", @"C", @"D"]];
    NSUInteger reads = self.peers[2].diagnosticReads;
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { report = value; }];
    XCTAssertNil(report[@"lastInterruption"]);
    XCTAssertEqual(self.peers[2].diagnosticReads, reads);
}
- (void)testInputDiagnosticsTimeoutIsPartialAndLateReplyCannotChangeTheReport {
    [self.sync start];
    [self.sync pause];
    self.peers[2].holdDiagnostics = YES;
    XCTestExpectation *completed = [self expectationWithDescription:@"bounded diagnostic read"];
    __block NSDictionary *report;
    __block NSUInteger callbacks = 0;
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { report = value; callbacks++; [completed fulfill]; }];
    __block NSDictionary *duplicate;
    [self.sync readInputDiagnosticsWithReply:^(NSDictionary *value) { duplicate = value; }];
    XCTAssertEqualObjects(duplicate[@"guestReadStatus"], @"alreadyReading");
    XCTAssertEqual(self.peers[2].diagnosticReads, 1u);
    [self waitForExpectations:@[completed] timeout:5];
    XCTAssertEqualObjects(report[@"guestReadStatus"], @"partial");
    XCTAssertEqualObjects(report[@"guests"][2][@"readStatus"], @"timedOut");
    [self.sync start];
    NSString *resumedSession = self.peers[0].session;
    self.peers[2].pendingDiagnostics(@{@"lastInputFailure": @{@"reason": @"inputTooOld", @"stage": @"guestReceive", @"mode": @"tapsOnly"}});
    self.peers[2].pendingDiagnostics = nil;
    XCTAssertEqual(callbacks, 1u);
    XCTAssertEqualObjects(report[@"guests"][2][@"readStatus"], @"timedOut");
    XCTAssertTrue(self.sync.active);
    XCTAssertEqualObjects(self.peers[0].session, resumedSession);
}
- (void)testLoadingPreparationCanRecoverAfterOriginalThreeSecondLimit {
    self.peers[3].holdPreparation = YES;
    [self.sync start];
    XCTestExpectation *ready = [self expectationWithDescription:@"slow game startup"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        XCTAssertTrue(self.sync.starting);
        self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
        self.peers[3].pendingPreparation = nil;
        [ready fulfill];
    });
    [self waitForExpectations:@[ready] timeout:5];
    XCTAssertTrue(self.sync.active);
}
- (void)testInitializingWindowRetriesBeyondFirstThreeAttemptsWithoutBypassingDialogs {
    self.peers[3].preparationResult = LCTapSyncResultWindowNotReady;
    [self.sync start];
    XCTestExpectation *initializing = [self expectationWithDescription:@"unready window initializes"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        XCTAssertTrue(self.sync.starting);
        XCTAssertGreaterThan(self.peers[3].prepares, 3u);
        self.peers[3].preparationResult = LCTapSyncResultAccepted;
        [initializing fulfill];
    });
    [self waitForExpectations:@[initializing] timeout:3];
    [self waitUntil:^BOOL { return self.sync.active; }];
    [self.sync pause];
    NSUInteger prepares = self.peers[3].prepares;
    self.peers[3].preparationResult = LCTapSyncResultWindowCovered;
    [self.sync start];
    XCTAssertFalse(self.sync.active || self.sync.starting);
    XCTAssertEqual(self.peers[3].prepares, prepares + 1);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.windowCovered");
}
- (void)testForegroundDepartureDropsQueueAndOnlyManualResumeStartsFreshSession {
    // A switch left behind by the withdrawn prototype must not enable recovery,
    // even if written after the coordinator was created.
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncAutoResumeOnForeground"];
    self.peers[3].holdReplay = YES;
    [self.sync start];
    NSString *previous = self.peers[0].session;
    self.peers[0].didReceiveTap(self.freshTap, previous, 1);
    self.peers[0].didReceiveTap(self.freshTap, previous, 2);
    void (^oldReply)(LCTapSyncResult) = self.peers[3].pendingReplay;
    [self.sync hostWillResignActive:nil];
    [self.sync hostDidEnterBackground:nil];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    XCTAssertFalse(self.sync.canStart);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
    for (LCTestSyncPeer *peer in self.peers) { XCTAssertNil(peer.session); XCTAssertEqual(peer.stops, 1u); }
    [self.sync hostDidBecomeActive:nil];
    [self.sync hostSceneDidActivate:[NSNotification notificationWithName:UISceneDidActivateNotification object:self.window.windowScene]];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    XCTAssertTrue(self.sync.canStart);
    for (LCTestSyncPeer *peer in self.peers) XCTAssertEqual(peer.prepares, 1u);
    oldReply(LCTapSyncResultAccepted);
    self.peers[0].didReceiveTap(self.freshTap, previous, 3);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
    self.peers[3].holdReplay = NO;
    [self.sync start];
    XCTAssertTrue(self.sync.active);
    XCTAssertNotEqualObjects(self.peers[0].session, previous);
    oldReply(LCTapSyncResultAccepted);
    self.peers[0].didReceiveTap(self.freshTap, previous, 4);
    for (NSUInteger i = 1; i < 4; i++) XCTAssertEqual(self.peers[i].replays, 1u);
    self.peers[0].didReceiveTap(self.freshTap, self.peers[0].session, 1);
    XCTAssertEqual(self.sync.forwardedTapCount, 1u);
    for (NSUInteger i = 1; i < 4; i++) XCTAssertEqual(self.peers[i].replays, 2u);
}
- (void)testSystemOverlayReturnStaysPausedWithSourceAndRotationOptionsEnabled {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    self.sync.autoResumeAfterRotation = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[UIApplicationWillResignActiveNotification, UISceneWillDeactivateNotification]) {
        [self.sync start];
        NSString *previous = self.peers[0].session;
        id object = [name isEqualToString:UISceneWillDeactivateNotification] ? self.window.windowScene : UIApplication.sharedApplication;
        [center postNotificationName:name object:object];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        // No background transition: this models temporary deactivation while a
        // system surface is shown, not a physical status-bar swipe in the test.
        [self.sync hostSceneDidActivate:[NSNotification notificationWithName:UISceneDidActivateNotification object:self.window.windowScene]];
        [self.sync hostDidBecomeActive:nil];
        [self letRecoveryCheckFinish];
        [self.peers[0] inputTouching:YES began:YES];
        [self.peers[0] inputTouching:NO began:NO];
        [self letRecoveryCheckFinish];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        XCTAssertTrue(self.sync.canStart);
        XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
        [self.sync start];
        XCTAssertTrue(self.sync.active);
        XCTAssertNotEqualObjects(self.peers[0].session, previous);
        [self.sync pause];
    }
}
- (void)testManualResumeRequiresActualHostActivationAndIgnoresOldActivationCallback {
    [self.sync start];
    [self.sync hostWillResignActive:nil];
    self.sync.reportsActivationPending = YES;
    [self.sync hostDidBecomeActive:nil];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.canStart);
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    [self.sync start];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    for (LCTestSyncPeer *peer in self.peers) XCTAssertEqual(peer.prepares, 1u);
    // A later public state is sufficient for an explicit start; no extra
    // lifecycle callback is required to clear an old notification latch.
    self.sync.reportsActivationPending = NO;
    [self.sync validateWindows];
    XCTAssertTrue(self.sync.canStart);
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    [self.sync start];
    XCTAssertTrue(self.sync.active);
    [self.sync hostWillResignActive:nil];
    [self.sync hostDidBecomeActive:nil];
    [self.sync hostWillResignActive:nil];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.canStart);
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    [self.sync hostDidBecomeActive:nil];
    XCTAssertTrue(self.sync.canStart);
    [self.sync start];
    XCTAssertTrue(self.sync.active);
}
- (void)testForegroundDepartureCancelsStartupFollowerAndRotationRecovery {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    self.sync.autoResumeAfterRotation = YES;
    for (NSNumber *phase in @[@0, @1, @2]) {
        void (^oldPreparation)(LCTapSyncResult) = nil;
        CGRect original = self.host.tapSyncWindows[0].view.frame;
        if (phase.integerValue == 0) self.peers[3].holdPreparation = YES;
        [self.sync start];
        if (phase.integerValue == 0) {
            oldPreparation = self.peers[3].pendingPreparation;
            XCTAssertTrue(self.sync.starting);
        } else if (phase.integerValue == 1) {
            [self.peers[1] inputTouching:YES began:YES];
            XCTAssertTrue(self.sync.recovering);
        } else {
            self.sync.animatingRotation = YES;
            self.host.tapSyncWindows[0].view.frame = CGRectOffset(original, 0, 2);
            [self.sync validateWindows];
            XCTAssertTrue(self.sync.recovering);
        }
        [self.sync hostDidEnterBackground:nil];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        if (oldPreparation) oldPreparation(LCTapSyncResultAccepted);
        self.peers[3].holdPreparation = NO;
        self.peers[3].pendingPreparation = nil;
        self.peers[1].touching = NO;
        self.sync.animatingRotation = NO;
        self.host.tapSyncWindows[0].view.frame = original;
        [self.sync hostDidBecomeActive:nil];
        [self letRecoveryCheckFinish];
        [self.peers[0] inputTouching:YES began:YES];
        [self.peers[0] inputTouching:NO began:NO];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
        [self.sync start];
        XCTAssertTrue(self.sync.active);
        [self.sync pause];
    }
}
- (void)testManualForegroundResumePreparesEveryWindowAndRejectsHeldTouchKeyboardAndDialog {
    [self.sync start];
    [self.sync hostDidEnterBackground:nil];
    self.peers[3].holdPreparation = YES;
    [self.sync hostDidBecomeActive:nil];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    [self.sync start];
    XCTAssertTrue(self.sync.starting);
    XCTAssertFalse(self.sync.active);
    self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
    self.peers[3].pendingPreparation = nil;
    self.peers[3].holdPreparation = NO;
    XCTAssertTrue(self.sync.active);
    for (NSNumber *reason in @[@(LCTapSyncResultPhysicalTouch), @(LCTapSyncResultKeyboardVisible), @(LCTapSyncResultWindowCovered)]) {
        [self.sync hostDidEnterBackground:nil];
        [self.sync hostDidBecomeActive:nil];
        self.peers[3].preparationResult = reason.integerValue;
        [self.sync start];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        XCTAssertEqualObjects(self.sync.interruptedContainers, (@[@"D"]));
        NSString *status = self.sync.statusKey;
        self.peers[3].preparationResult = LCTapSyncResultAccepted;
        [self.sync hostDidBecomeActive:nil];
        [self letRecoveryCheckFinish];
        XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
        XCTAssertEqualObjects(self.sync.statusKey, status);
        [self.sync start];
        XCTAssertTrue(self.sync.active);
    }
}
- (void)testOtherSceneNotificationsDoNotPauseTheRunningHost {
    [self.sync start];
    NSObject *otherScene = [NSObject new];
    [self.sync hostSceneWillDeactivate:[NSNotification notificationWithName:UISceneWillDeactivateNotification object:otherScene]];
    [self.sync hostSceneDidEnterBackground:[NSNotification notificationWithName:UISceneDidEnterBackgroundNotification object:otherScene]];
    [self.sync hostSceneDidActivate:[NSNotification notificationWithName:UISceneDidActivateNotification object:otherScene]];
    XCTAssertTrue(self.sync.active);
}
- (void)testRetiredForegroundPreferenceIsClearedWithoutChangingSavedGroupOrOtherOptions {
    self.sync.resumeOnSource = YES;
    self.sync.syncReturnGesture = YES;
    self.sync.autoResumeAfterRotation = YES;
    self.sync.mode = LCTapSyncModeSingleFinger;
    [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCTapSyncAutoResumeOnForeground"];
    LCTapSyncCoordinator *restored = [LCTapSyncCoordinator new];
    XCTAssertNil([NSUserDefaults.lcSharedDefaults objectForKey:@"LCTapSyncAutoResumeOnForeground"]);
    XCTAssertEqualObjects(restored.sourceContainer, @"A");
    XCTAssertEqualObjects(restored.targetContainers, (@[@"B", @"C", @"D"]));
    XCTAssertEqual(restored.mode, LCTapSyncModeSingleFinger);
    XCTAssertTrue(restored.resumeOnSource && restored.syncReturnGesture && restored.autoResumeAfterRotation);
    XCTAssertFalse(restored.active || restored.starting || restored.recovering);
    XCTAssertEqualObjects(restored.statusKey, @"lc.tapSync.restoredPaused");
}
- (void)testGuestInactivityBeforeHostNotificationPausesUntilManualResume {
    [self.sync start];
    NSString *previous = self.peers[0].session;
    self.sync.reportsHostInactive = YES;
    self.peers[3].didInterrupt(previous, LCTapSyncResultSceneInactive);
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.backgroundPaused");
    [self.sync hostDidEnterBackground:nil];
    self.sync.reportsHostInactive = NO;
    [self.sync hostDidBecomeActive:nil];
    [self letRecoveryCheckFinish];
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
    [self.sync start];
    XCTAssertTrue(self.sync.active);
    XCTAssertNotEqualObjects(self.peers[0].session, previous);
}
- (void)testPreparationDeadlinePreservesReportedFailuresAndIgnoresLateReadiness {
    self.peers[1].preparationResult = LCTapSyncResultKeyboardVisible;
    self.peers[3].holdPreparation = YES;
    [self.sync start];
    [self waitUntil:^BOOL { return !self.sync.starting; } timeout:7];
    XCTAssertEqualObjects(self.sync.statusKey, @"lc.tapSync.startFailed");
    XCTAssertEqualObjects(self.sync.interruptedContainers, (@[@"B", @"D"]));
    XCTAssertEqualObjects([self.sync statusKeyForContainer:@"B"], @"lc.tapSync.keyboardVisible");
    XCTAssertEqualObjects([self.sync statusKeyForContainer:@"D"], @"lc.tapSync.preparationTimedOut");
    self.peers[3].pendingPreparation(LCTapSyncResultAccepted);
    XCTAssertFalse(self.sync.active || self.sync.starting || self.sync.recovering);
}
@end
