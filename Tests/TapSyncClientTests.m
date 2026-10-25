#import <XCTest/XCTest.h>
// Compile the production guest in the test bundle without activating its launch
// constructor (the test defaults provider reports that this is not LiveProcess).
#import "../TweakLoader/TapSyncClient.m"
#import "TapSyncTestWindow.h"

@interface LCTestInputHost : NSObject
@property(nonatomic) NSMutableArray<NSDictionary *> *input;
@property(nonatomic) NSUInteger taps, interrupts;
@property(nonatomic) NSMutableArray<NSDictionary *> *touches, *frames;
@property(nonatomic) NSUInteger returns;
@property(nonatomic) LCTapSyncResult reason;
@end
@implementation LCTestInputHost
- (instancetype)init {
    if ((self = [super init])) { _input = [NSMutableArray array]; _touches = [NSMutableArray array]; _frames = [NSMutableArray array]; }
    return self;
}
- (void)physicalInputChanged:(BOOL)touching began:(BOOL)began session:(NSString *)session revision:(uint64_t)revision
                    timestamp:(NSTimeInterval)timestamp returnRevision:(uint64_t)returnRevision {
    [self.input addObject:@{@"touching": @(touching), @"began": @(began), @"revision": @(revision), @"timestamp": @(timestamp),
                           @"returnRevision": @(returnRevision)}];
}
- (void)submitTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence { self.taps++; }
- (void)submitTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence {
    [self.touches addObject:@{@"touch": touch, @"session": session, @"sequence": @(sequence)}];
}
- (void)submitTouchFrame:(NSDictionary *)frame session:(NSString *)session sequence:(uint64_t)sequence {
    [self.frames addObject:@{@"frame": frame, @"session": session, @"sequence": @(sequence)}];
}
- (void)submitSourceReturn:(NSArray<NSDictionary *> *)packets session:(NSString *)session {
    self.returns++;
    uint64_t sequence = 0;
    for (NSDictionary *packet in packets) {
        sequence++;
        if (packet[@"tap"]) [self submitTap:packet[@"tap"] session:session sequence:sequence];
        else if (packet[@"touch"]) [self submitTouch:packet[@"touch"] session:session sequence:sequence];
        else [self submitTouchFrame:packet[@"frame"] session:session sequence:sequence];
    }
}
- (void)interruptSession:(NSString *)session reason:(LCTapSyncResult)reason { self.interrupts++; self.reason = reason; }
@end

@interface LCTestInputConnection : NSObject
@property(nonatomic) LCTestInputHost *host;
@end
@implementation LCTestInputConnection
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler { return self.host; }
@end

@interface LCTestInputTouch : UITouch
@property(nonatomic) UITouchPhase testPhase;
@property(nonatomic) UIWindow *testWindow;
@property(nonatomic) NSTimeInterval testTimestamp;
@end
@implementation LCTestInputTouch
- (UITouchPhase)phase { return self.testPhase; }
- (UITouchType)type { return UITouchTypeDirect; }
- (UIWindow *)window { return self.testWindow; }
- (NSTimeInterval)timestamp { return self.testTimestamp; }
- (NSUInteger)tapCount { return 1; }
- (CGPoint)locationInView:(UIView *)view { return CGPointMake(100, 100); }
@end

@interface LCTestInputEvent : UIEvent
@property(nonatomic, copy) NSSet<UITouch *> *testTouches;
@end
@implementation LCTestInputEvent
- (UIEventType)type { return UIEventTypeTouches; }
- (NSSet<UITouch *> *)allTouches { return self.testTouches; }
- (NSTimeInterval)timestamp {
    NSTimeInterval timestamp = 0;
    for (UITouch *touch in self.testTouches) timestamp = MAX(timestamp, touch.timestamp);
    return timestamp;
}
- (NSArray<UITouch *> *)coalescedTouchesForTouch:(UITouch *)touch { return @[touch]; }
@end

@interface LCTestInputClient : LCTapSyncClient
@property(nonatomic) NSUInteger cancellations;
@end
@implementation LCTestInputClient
// Keep actual finishReplay cleanup/reply behavior, while observing cancellation
// without injecting a synthetic touch into the simulator's event dispatcher.
- (BOOL)sendPhase:(UITouchPhase)phase timestamp:(NSTimeInterval)timestamp {
    if (phase == UITouchPhaseCancelled) self.cancellations++;
    return YES;
}
@end

@interface TapSyncClientTests : XCTestCase
@property(nonatomic) LCTestInputClient *client;
@property(nonatomic) LCTestInputConnection *connection;
@property(nonatomic) LCTestInputHost *host;
@property(nonatomic) UIWindow *window;
@end
@implementation TapSyncClientTests
- (void)setUp {
    [super setUp];
    self.window = LCTapSyncTestHostWindow();
    XCTAssertNotNil(self.window);
    XCTAssertEqual(LCTapSyncGuestWindow(), self.window);
    self.host = [LCTestInputHost new];
    self.connection = [LCTestInputConnection new];
    self.connection.host = self.host;
    self.client = [LCTestInputClient new];
    self.client.connection = (id)self.connection;
    self.client.session = NSUUID.UUID.UUIDString;
    self.client.supported = YES;
    self.client.resumeOnSource = YES;
}
- (void)tearDown {
    self.client.session = nil;
    [self.client finishReplay:LCTapSyncResultStopped];
    self.client.connection = nil;
    self.client = nil;
    self.connection = nil;
    self.host = nil;
    self.window = nil;
    [super tearDown];
}
- (void)testOnDemandGeometryReplyLeavesTheInputSessionAndCaptureUnchanged {
    NSString *session = self.client.session;
    BOOL source = self.client.source;
    XCTestExpectation *replied = [self expectationWithDescription:@"guest geometry arrives from the UI queue"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self.client readWindowGeometryWithReply:^(NSDictionary *geometry) {
            XCTAssertTrue(NSThread.isMainThread);
            XCTAssertTrue([NSJSONSerialization isValidJSONObject:geometry]);
            XCTAssertEqualObjects(self.client.session, session);
            XCTAssertEqual(self.client.source, source);
            XCTAssertEqual(self.host.taps, 0U);
            XCTAssertEqual(self.host.interrupts, 0U);
            [replied fulfill];
        }];
    });
    [self waitForExpectations:@[replied] timeout:5];
}
- (LCTestInputTouch *)touch {
    LCTestInputTouch *touch = [LCTestInputTouch new];
    touch.testWindow = self.window;
    touch.testTimestamp = NSProcessInfo.processInfo.systemUptime - 0.1;
    return touch;
}
- (void)observe:(LCTestInputTouch *)touch phase:(UITouchPhase)phase {
    touch.testPhase = phase;
    LCTestInputEvent *event = [LCTestInputEvent new];
    event.testTouches = [NSSet setWithObject:touch];
    [self.client observeEvent:event];
}
- (void)testSuspendedSourceReturnIsObservedButNotCaptured {
    self.client.source = YES;
    self.client.suspended = YES;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    XCTAssertTrue(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqualObjects(self.host.input.lastObject[@"began"], @YES);
    XCTAssertEqualObjects(self.host.input.lastObject[@"timestamp"], @(touch.testTimestamp));
    XCTAssertNil(self.client.candidate);
    XCTAssertEqual(self.host.taps, 0u);
    touch.testTimestamp += 0.05;
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqualObjects(self.host.input.lastObject[@"touching"], @NO);
    XCTAssertEqual(self.host.taps, 0u);
    // A fresh session captures the next complete gesture normally.
    self.client.session = NSUUID.UUID.UUIDString;
    self.client.suspended = NO;
    touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    touch.testTimestamp += 0.05;
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.host.taps, 1u);
}
- (void)testRealFollowerInputCancelsReplayAndSendsOnlyOneBegin {
    LCTestInputTouch *synthetic = self.touch;
    [self.client.inputState rememberSyntheticTouch:synthetic];
    self.client.syntheticTouch = synthetic;
    self.client.syntheticContactDown = YES;
    __block NSUInteger replies = 0;
    self.client.replayReply = ^(LCTapSyncResult result) { XCTAssertEqual(result, LCTapSyncResultSuspended); replies++; };
    LCTestInputTouch *physical = self.touch;
    [self observe:physical phase:UITouchPhaseBegan];
    XCTAssertTrue(self.client.suspended);
    XCTAssertEqual(self.client.cancellations, 1u);
    XCTAssertEqual(replies, 1u);
    XCTAssertNil(self.client.syntheticTouch);
    XCTAssertTrue(self.client.inputState.hasPhysicalTouches);
    NSUInteger begins = 0;
    for (NSDictionary *input in self.host.input) if ([input[@"began"] boolValue]) begins++;
    XCTAssertEqual(begins, 1u);
    [self observe:physical phase:UITouchPhaseStationary];
    XCTAssertEqual(self.client.cancellations, 1u);
    [self observe:physical phase:UITouchPhaseEnded];
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqualObjects(self.host.input.lastObject[@"touching"], @NO);
    XCTAssertNotNil(self.client.session);
}
- (void)testPhysicalTouchWithOptionOffRequiresManualResume {
    self.client.resumeOnSource = NO;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    XCTAssertNil(self.client.session);
    XCTAssertEqual(self.host.interrupts, 1u);
    XCTAssertEqual(self.host.reason, LCTapSyncResultPhysicalTouch);
    XCTAssertTrue(self.client.inputState.hasPhysicalTouches);
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqual(self.host.input.count, 0u);
}
- (void)testGeometrySuspensionKeepsPhysicalObservation {
    self.client.source = YES;
    self.client.resumeOnSource = NO;
    NSString *session = self.client.session;
    [self.client interrupt:LCTapSyncResultGeometryChanged];
    XCTAssertEqualObjects(self.client.session, session);
    XCTAssertTrue(self.client.suspended);
    XCTAssertEqual(self.client.suspensionResult, LCTapSyncResultGeometryChanged);
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.host.input.count, 2u);
    XCTAssertEqual(self.host.taps, 0u);
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
}
- (void)testOwnedTouchesAndOtherWindowsCannotSignalSourceReturn {
    self.client.source = YES;
    self.client.suspended = YES;
    LCTestInputTouch *synthetic = self.touch;
    [self.client.inputState rememberSyntheticTouch:synthetic];
    [self observe:synthetic phase:UITouchPhaseBegan];
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqual(self.host.input.count, 0u);
    LCTestInputTouch *other = self.touch;
    other.testWindow = [[UIWindow alloc] initWithFrame:self.window.bounds];
    [self observe:other phase:UITouchPhaseBegan];
    XCTAssertTrue(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqualObjects(self.host.input.lastObject[@"began"], @NO);
    [self observe:other phase:UITouchPhaseCancelled];
    XCTAssertFalse(self.client.inputState.hasPhysicalTouches);
}
- (void)testFirstReturnTapCapturedAndDeliveredWithoutExtraTouch {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    NSString *previous = self.client.session;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    uint64_t revision = self.client.returnGesture.revision;
    XCTAssertNotEqual(revision, 0u);
    XCTAssertEqualObjects(self.host.input.lastObject[@"returnRevision"], @(revision));
    XCTAssertEqual(self.host.taps, 0u);
    touch.testTimestamp += 0.05;
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.client.returnGesture.packets.count, 1u);
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultAccepted);
    XCTAssertEqual(self.host.taps, 1u);
    XCTAssertEqual(self.host.returns, 1u);
    XCTAssertFalse(self.client.suspended);
    XCTAssertNil(self.client.returnGesture);
}
- (void)testFirstReturnSingleFingerContinuesHeldGesture {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    self.client.mode = LCTapSyncModeSingleFinger;
    NSString *previous = self.client.session;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    uint64_t revision = self.client.returnGesture.revision;
    XCTAssertEqual(self.host.touches.count, 0u);
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultAccepted);
    XCTAssertTrue(self.client.inputState.hasPhysicalTouches);
    XCTAssertEqual(self.host.touches.count, 1u);
    touch.testTimestamp += 0.05;
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.host.touches.count, 2u);
    XCTAssertEqualObjects(self.host.touches[0][@"touch"][@"phase"], @(LCTouchSyncPhaseBegan));
    XCTAssertEqualObjects(self.host.touches[1][@"touch"][@"phase"], @(LCTouchSyncPhaseEnded));
    XCTAssertEqualObjects(self.host.touches[0][@"touch"][@"contact"], self.host.touches[1][@"touch"][@"contact"]);
    XCTAssertEqualObjects(self.host.touches[0][@"session"], self.host.touches[1][@"session"]);
    XCTAssertEqualObjects(self.host.touches[1][@"sequence"], @2);
}
- (void)testFirstReturnTwoFingerReleasesRetainContactBoundaries {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    self.client.mode = LCTapSyncModeTwoFingers;
    NSString *previous = self.client.session;
    LCTestInputTouch *first = self.touch, *second = self.touch;
    first.testPhase = second.testPhase = UITouchPhaseBegan;
    LCTestInputEvent *event = [LCTestInputEvent new];
    event.testTouches = [NSSet setWithObjects:first, second, nil];
    [self.client observeEvent:event];
    uint64_t revision = self.client.returnGesture.revision;
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultAccepted);
    XCTAssertEqual(self.host.frames.count, 1u);
    first.testPhase = UITouchPhaseEnded;
    second.testPhase = UITouchPhaseStationary;
    first.testTimestamp = second.testTimestamp = MAX(first.testTimestamp, second.testTimestamp) + 0.03;
    [self.client observeEvent:event];
    event.testTouches = [NSSet setWithObject:second];
    second.testPhase = UITouchPhaseEnded;
    second.testTimestamp += 0.05;
    [self.client observeEvent:event];
    XCTAssertEqual(self.host.frames.count, 3u);
    LCMultiTouchSyncStream stream = {0};
    for (NSDictionary *packet in self.host.frames) {
        LCMultiTouchSyncFrame frame;
        XCTAssertTrue(LCMultiTouchSyncDecode(packet[@"frame"], &frame));
        XCTAssertTrue(LCMultiTouchSyncAdvance(&stream, frame));
    }
    XCTAssertEqual(stream.count, 0u);
    XCTAssertFalse(stream.cancelled);
}
- (void)testCancelledStaleOrUnrelatedReturnCannotResume {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    self.client.mode = LCTapSyncModeSingleFinger;
    NSString *previous = self.client.session;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    uint64_t revision = self.client.returnGesture.revision;
    LCTestInputTouch *other = self.touch;
    [self.client.inputState observePhysicalTouch:other active:YES];
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultPhysicalTouch);
    [self.client.inputState observePhysicalTouch:other active:NO];
    self.client.returnBounds = CGRectZero;
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultGeometryChanged);
    self.client.returnBounds = self.window.bounds;
    self.client.returnGesture = [[LCTapSyncReturnGesture alloc] initWithMode:self.client.mode revision:revision atTime:NSProcessInfo.processInfo.systemUptime - 1];
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultExpired);
    self.client.session = nil;
    XCTAssertNil(self.client.returnGesture);
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultStopped);
    XCTAssertEqual(self.host.touches.count, 0u);
}
- (void)testFirstReturnTapResumesOnDownAndCompletesOnce {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    NSString *previous = self.client.session;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    uint64_t revision = self.client.returnGesture.revision;
    NSString *session = NSUUID.UUID.UUIDString;
    XCTAssertEqual([self.client resumeSource:session previousSession:previous inputRevision:revision], LCTapSyncResultAccepted);
    XCTAssertEqual(self.host.returns, 1u);
    XCTAssertEqual(self.host.taps, 0u);
    XCTAssertEqual(self.client.sequence, 0u);
    touch.testTimestamp += 0.05;
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.host.taps, 1u);
    XCTAssertEqual(self.client.sequence, 1u);
    XCTAssertEqual([self.client resumeSource:NSUUID.UUID.UUIDString previousSession:previous inputRevision:revision], LCTapSyncResultStopped);
    XCTAssertEqual(self.host.taps, 1u);
}
- (void)testDelayedFollowerInvalidationKeepsNewerSourceReturn {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    self.client.mode = LCTapSyncModeSingleFinger;
    LCTestInputTouch *touch = self.touch;
    [self observe:touch phase:UITouchPhaseBegan];
    LCTapSyncReturnGesture *gesture = self.client.returnGesture;
    XCTAssertNotNil(gesture);
    [self.client discardSourceReturnBeforeTime:touch.timestamp - 0.01];
    XCTAssertEqual(self.client.returnGesture, gesture);
    XCTAssertNotNil(self.client.candidate);
    [self.client discardSourceReturnBeforeTime:touch.timestamp + 0.01];
    XCTAssertNil(self.client.returnGesture);
    XCTAssertNil(self.client.candidate);
    XCTAssertEqualObjects(self.host.input.lastObject[@"returnRevision"], @0);
    touch.testTimestamp += 0.005;
    [self observe:touch phase:UITouchPhaseEnded];
    // An old event delivered after invalidation cannot start a return capture.
    touch = self.touch;
    touch.testTimestamp = gesture.beganAt + 0.005;
    [self observe:touch phase:UITouchPhaseBegan];
    XCTAssertNil(self.client.returnGesture);
    [self observe:touch phase:UITouchPhaseEnded];
    XCTAssertEqual(self.host.touches.count, 0u);
}
- (void)testSourceDownSnapshotBeforeCaptureStillPublishesReturnToken {
    self.client.source = YES;
    self.client.suspended = YES;
    self.client.syncReturnGesture = YES;
    self.client.mode = LCTapSyncModeSingleFinger;
    LCTestInputTouch *touch = self.touch;
    touch.testPhase = UITouchPhaseBegan;
    LCTestInputEvent *event = [LCTestInputEvent new];
    event.testTouches = [NSSet setWithObject:touch];
    [self.client observePhysicalInput:event];
    XCTAssertEqualObjects(self.host.input.lastObject[@"returnRevision"], @0);
    [self.client observeEvent:event];
    uint64_t revision = self.client.returnGesture.revision;
    XCTAssertNotEqual(revision, 0u);
    XCTAssertEqualObjects(self.host.input.lastObject[@"returnRevision"], @(revision));
    XCTAssertEqualObjects(self.host.input.lastObject[@"began"], @YES);
    XCTAssertEqual(self.client.returnGesture.packets.count, 1u);
    NSUInteger notifications = self.host.input.count;
    touch.testPhase = UITouchPhaseStationary;
    [self.client observeEvent:event];
    XCTAssertEqual(self.host.input.count, notifications);
}
@end
