#import <XCTest/XCTest.h>
// Compile the production guest in the test bundle without activating its launch
// constructor (the test defaults provider reports that this is not LiveProcess).
#import "../TweakLoader/TapSyncClient.m"

@interface LCTestInputHost : NSObject
@property(nonatomic) NSMutableArray<NSDictionary *> *input;
@property(nonatomic) NSUInteger taps, interrupts;
@property(nonatomic) LCTapSyncResult reason;
@end
@implementation LCTestInputHost
- (instancetype)init {
    if ((self = [super init])) _input = [NSMutableArray array];
    return self;
}
- (void)physicalInputChanged:(BOOL)touching began:(BOOL)began session:(NSString *)session revision:(uint64_t)revision timestamp:(NSTimeInterval)timestamp {
    [self.input addObject:@{@"touching": @(touching), @"began": @(began), @"revision": @(revision), @"timestamp": @(timestamp)}];
}
- (void)submitTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence { self.taps++; }
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
    self.window.hidden = YES;
    self.window.windowScene = nil;
    self.window.rootViewController = nil;
    self.window = nil;
    [super tearDown];
}
- (LCTestInputTouch *)touch {
    LCTestInputTouch *touch = [LCTestInputTouch new];
    touch.testWindow = self.window;
    touch.testTimestamp = NSProcessInfo.processInfo.systemUptime;
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
@end
