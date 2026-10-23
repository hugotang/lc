#import "TapSyncCoordinator.h"
#import "TapSyncSession.h"
#import "TapSyncSelection.h"
#import "TapSyncRecovery.h"
#import "PerformanceMetrics.h"
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/utils.h"
#include <math.h>

NSNotificationName const LCTapSyncDidChangeNotification = @"LCTapSyncDidChange";

@interface LCTapSyncCoordinator ()
@property(nonatomic) NSMapTable<NSString *, AppSceneViewController *> *scenes;
@property(nonatomic) LCTapSyncSelectionStore *selectionStore;
@property(nonatomic) LCTapSyncSession *session;
@property(nonatomic) LCTapSyncPreparation *preparation;
@property(nonatomic) LCTapSyncRecovery *recovery;
@property(nonatomic) LCTapSyncSession *recoverySession;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *inputRevisions;
@property(nonatomic) NSMutableSet<NSString *> *touchingContainers;
@property(nonatomic) BOOL recoveryCheckScheduled;
@property(nonatomic) BOOL recoveryAllowsGeometryChange;
@property(nonatomic) NSTimeInterval recoveryReadyDeadline;
@property(nonatomic) NSDictionary<NSString *, NSString *> *interruptionStatusKeys;
@property(nonatomic) NSArray *geometry;
@property(nonatomic) uint64_t inFlightSequence;
@property(nonatomic) uint64_t deliverySequence;
@property(nonatomic, strong) dispatch_source_t replyTimer;
@property(nonatomic) NSArray *lastWindowPresentation;
@property(nonatomic) NSDictionary<NSString *, NSNumber *> *participantNumbers;
@property(nonatomic) NSMutableOrderedSet<NSString *> *awaitingReplies;
@property(nonatomic) LCPerformanceResponseHistory responseHistory;
@property(nonatomic) NSUInteger measuredPackets, measuredCoalescedMoves, measuredQueuePeak, performanceGeneration;
- (void)physicalInputForContainer:(NSString *)container session:(NSString *)identifier revision:(uint64_t)revision touching:(BOOL)touching began:(BOOL)began timestamp:(NSTimeInterval)timestamp;
- (void)beginRecovery:(LCTapSyncRecoveryReason)reason containers:(NSArray<NSString *> *)containers;
- (void)cancelRecoveryStoppingGuests:(BOOL)stop;
- (void)scheduleRecoveryCheck;
- (BOOL)shouldRecoverForRotation;
- (BOOL)hostRotatedSinceGeometry:(NSArray *)geometry;
- (BOOL)hostIsAnimatingRotation;
- (void)startPreservingCount:(BOOL)preserveCount;
@end

@implementation LCTapSyncCoordinator
+ (instancetype)shared {
    static LCTapSyncCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _scenes = [NSMapTable strongToWeakObjectsMapTable];
        _interruptedContainers = @[];
        _inputRevisions = [NSMutableDictionary dictionary];
        _touchingContainers = [NSMutableSet set];
        _selectionStore = [[LCTapSyncSelectionStore alloc] initWithDefaults:NSUserDefaults.lcSharedDefaults];
        LCTapSyncSelection *selection = [_selectionStore loadSelection];
        _sourceContainer = selection.source;
        _targetContainers = selection.targets;
        _mode = selection.mode;
        _statusKey = _sourceContainer && _targetContainers.count ? @"lc.tapSync.restoredPaused" : @"lc.tapSync.chooseWindows";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostWillResignActive:)
                                                   name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostDidBecomeActive:)
                                                   name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:LCTapSyncDidChangeNotification object:self];
}
- (void)registerScene:(AppSceneViewController *)scene {
    if (!scene.tapSyncPeer) return;
    [self.scenes setObject:scene forKey:scene.dataUUID];
    __weak typeof(self) weakSelf = self;
    __weak AppSceneViewController *weakScene = scene;
    scene.tapSyncPeer.stateDidChange = ^{
        LCTapSyncCoordinator *coordinator = weakSelf;
        AppSceneViewController *current = weakScene;
        if (!coordinator || !current) return;
        if (!current.tapSyncPeer.ready && [coordinator isParticipant:current.dataUUID]) {
            [coordinator stopWithStatus:@"lc.tapSync.unavailable" containers:@[current.dataUUID]];
        }
        if (!coordinator.session && [coordinator.statusKey isEqualToString:@"lc.tapSync.unavailable"] && coordinator.interruptedContainers.count) {
            BOOL reconnected = YES;
            for (NSString *container in coordinator.interruptedContainers) {
                if (![coordinator isReadyForContainer:container]) { reconnected = NO; break; }
            }
            if (reconnected) {
                coordinator->_statusKey = @"lc.tapSync.reconnectedPaused";
                coordinator->_interruptedContainers = @[];
                coordinator.interruptionStatusKeys = @{};
            }
        }
        [coordinator changed];
    };
    scene.tapSyncPeer.didReceiveTap = ^(NSDictionary *tap, NSString *session, uint64_t sequence) {
        [weakSelf receiveTap:tap source:weakScene.dataUUID session:session sequence:sequence];
    };
    scene.tapSyncPeer.didReceiveTouch = ^(NSDictionary *touch, NSString *session, uint64_t sequence) {
        [weakSelf receiveTouch:touch source:weakScene.dataUUID session:session sequence:sequence];
    };
    scene.tapSyncPeer.didReceiveTouchFrame = ^(NSDictionary *frame, NSString *session, uint64_t sequence) {
        [weakSelf receiveTouchFrame:frame source:weakScene.dataUUID session:session sequence:sequence];
    };
    scene.tapSyncPeer.didInterrupt = ^(NSString *session, LCTapSyncResult reason) {
        LCTapSyncCoordinator *coordinator = weakSelf;
        if ([coordinator.recoverySession.identifier isEqualToString:session] && [coordinator isParticipant:weakScene.dataUUID]) {
            if (reason == LCTapSyncResultGeometryChanged && (coordinator.recoveryAllowsGeometryChange ||
                (coordinator.autoResumeAfterRotation && [coordinator hostRotatedSinceGeometry:coordinator.geometry]))) {
                coordinator.recoveryAllowsGeometryChange = YES;
                [coordinator scheduleRecoveryCheck];
                return;
            }
            [coordinator stopWithResult:reason containers:@[weakScene.dataUUID]];
        } else if ([coordinator.session.identifier isEqualToString:session] && [coordinator isParticipant:weakScene.dataUUID]) {
            [coordinator stopWithResult:reason containers:@[weakScene.dataUUID]];
        }
    };
    scene.tapSyncPeer.didChangePhysicalInput = ^(NSString *session, uint64_t revision, BOOL touching, BOOL began, NSTimeInterval timestamp) {
        [weakSelf physicalInputForContainer:weakScene.dataUUID session:session revision:revision touching:touching began:began timestamp:timestamp];
    };
    [self changed];
}
- (void)unregisterScene:(AppSceneViewController *)scene {
    if ([self.scenes objectForKey:scene.dataUUID] != scene) return;
    if ([self isParticipant:scene.dataUUID]) [self stopWithStatus:@"lc.tapSync.unavailable" containers:@[scene.dataUUID]];
    [self.scenes removeObjectForKey:scene.dataUUID];
    [scene.tapSyncPeer invalidate];
    [self changed];
}
- (BOOL)isParticipant:(NSString *)container {
    LCTapSyncSession *session = self.session ?: self.recoverySession;
    return session && ([session.source isEqualToString:container] || [session.targets containsObject:container]);
}
- (BOOL)isRecovering { return self.recovery != nil; }
- (BOOL)resumeOnSource { return [NSUserDefaults.lcSharedDefaults boolForKey:@"LCTapSyncResumeOnSource"]; }
- (void)setResumeOnSource:(BOOL)value {
    if (value == self.resumeOnSource) return;
    [self pause];
    [NSUserDefaults.lcSharedDefaults setBool:value forKey:@"LCTapSyncResumeOnSource"];
    [self changed];
}
- (BOOL)autoResumeAfterRotation { return [NSUserDefaults.lcSharedDefaults boolForKey:@"LCTapSyncAutoResumeAfterRotation"]; }
- (void)setAutoResumeAfterRotation:(BOOL)value {
    if (value == self.autoResumeAfterRotation) return;
    [self pause];
    [NSUserDefaults.lcSharedDefaults setBool:value forKey:@"LCTapSyncAutoResumeAfterRotation"];
    [self changed];
}
- (BOOL)isReadyForContainer:(NSString *)container { return [self.scenes objectForKey:container].tapSyncPeer.ready; }
- (BOOL)canReplayForContainer:(NSString *)container { return [self.scenes objectForKey:container].tapSyncPeer.canReplay; }
- (NSDictionary<NSString *, LCTapSyncPeer *> *)performancePeers {
    NSMutableDictionary *peers = [NSMutableDictionary dictionary];
    for (NSString *container in self.scenes.keyEnumerator) {
        AppSceneViewController *scene = [self.scenes objectForKey:container];
        if (scene.isAppRunning && scene.tapSyncPeer) peers[container] = scene.tapSyncPeer;
    }
    return peers.copy;
}
- (NSUInteger)windowNumberForContainer:(NSString *)container {
    NSArray<LCWorkspaceWindow *> *windows = self.availableWindows;
    NSUInteger index = [windows indexOfObjectPassingTest:^BOOL(LCWorkspaceWindow *window, NSUInteger index, BOOL *stop) {
        return [window.dataUUID isEqualToString:container];
    }];
    return index == NSNotFound ? [self.participantNumbers[container] unsignedIntegerValue] : index + 1;
}
- (void)useAsSource:(NSString *)container {
    if ([container isEqualToString:self.sourceContainer] || ![self isReadyForContainer:container]) return;
    NSArray<LCWorkspaceWindow *> *windows = self.availableWindows;
    LCWorkspaceWindow *previous = nil, *next = nil;
    for (LCWorkspaceWindow *window in windows) {
        if ([window.dataUUID isEqualToString:self.sourceContainer]) previous = window;
        if ([window.dataUUID isEqualToString:container]) next = window;
    }
    if (!next) return;
    NSMutableOrderedSet *targets = [NSMutableOrderedSet orderedSet];
    if ((previous && [previous.bundleName isEqualToString:next.bundleName]) || [self.targetContainers containsObject:container]) {
        NSMutableDictionary<NSString *, LCWorkspaceWindow *> *visible = [NSMutableDictionary dictionary];
        for (LCWorkspaceWindow *window in windows) visible[window.dataUUID] = window;
        for (NSString *target in self.targetContainers) {
            if ([target isEqualToString:container]) continue;
            LCWorkspaceWindow *window = visible[target];
            // Temporarily closed accounts stay selected until explicitly removed.
            if (!window || [window.bundleName isEqualToString:next.bundleName]) [targets addObject:target];
        }
        if (previous && [self canReplayForContainer:previous.dataUUID]) [targets addObject:previous.dataUUID];
        else if (!previous && self.sourceContainer) [targets addObject:self.sourceContainer];
    }
    [self selectSource:container targets:targets.array];
}
- (void)removeTarget:(NSString *)container {
    if (![self.targetContainers containsObject:container]) return;
    NSMutableArray *targets = self.targetContainers.mutableCopy;
    [targets removeObject:container];
    NSMutableArray *remainingIssues = self.interruptedContainers.mutableCopy;
    [remainingIssues removeObject:container];
    NSString *status = self.statusKey;
    NSDictionary *reasons = self.interruptionStatusKeys;
    [self selectSource:self.sourceContainer targets:targets];
    if (remainingIssues.count && targets.count) {
        _interruptedContainers = remainingIssues.copy;
        _statusKey = status;
        NSMutableDictionary *remainingReasons = [NSMutableDictionary dictionary];
        for (NSString *remaining in remainingIssues) if (reasons[remaining]) remainingReasons[remaining] = reasons[remaining];
        self.interruptionStatusKeys = remainingReasons.copy;
        [self changed];
    }
}
- (NSArray<LCWorkspaceWindow *> *)availableWindows {
    NSMutableArray *windows = [NSMutableArray array];
    for (DecoratedAppSceneViewController *controller in self.host.tapSyncWindows) {
        LCWorkspaceWindow *window = [[LCWorkspaceWindow alloc] initWithBundleName:controller.appSceneVC.bundleId
            dataUUID:controller.appSceneVC.dataUUID scale:controller.scaleRatio];
        if (window) [windows addObject:window];
    }
    return windows.copy;
}
- (void)selectSource:(NSString *)source targets:(NSArray<NSString *> *)targets {
    [self pause];
    LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithSource:source targets:targets mode:self.mode];
    _sourceContainer = selection.source;
    _targetContainers = selection.targets;
    [self.selectionStore saveSelection:selection];
    [self resetPerformanceData];
    _forwardedTapCount = 0;
    _statusKey = self.sourceContainer && self.targetContainers.count ? @"lc.tapSync.paused" : @"lc.tapSync.chooseWindows";
    [self changed];
}
- (void)setMode:(LCTapSyncMode)mode {
    if (mode != LCTapSyncModeTapsOnly && mode != LCTapSyncModeSingleFinger && mode != LCTapSyncModeTwoFingers) return;
    if (_mode == mode) return;
    [self pause];
    _mode = mode;
    [self resetPerformanceData];
    _forwardedTapCount = 0;
    _statusKey = self.sourceContainer && self.targetContainers.count ? @"lc.tapSync.paused" : @"lc.tapSync.chooseWindows";
    [self.selectionStore saveSelection:[[LCTapSyncSelection alloc] initWithSource:self.sourceContainer targets:self.targetContainers mode:mode]];
    [self changed];
}
- (NSDictionary *)selectionPropertyList {
    return [[LCTapSyncSelection alloc] initWithSource:self.sourceContainer targets:self.targetContainers mode:self.mode].groupPropertyList;
}
- (void)restoreSelection:(NSDictionary *)selection {
    LCTapSyncSelection *restored = [[LCTapSyncSelection alloc] initWithGroupPropertyList:selection];
    // An explicit workspace restore replaces the last choice, always paused.
    [self pause];
    _mode = restored.mode;
    [self selectSource:restored.source targets:restored.targets];
    if (self.sourceContainer && self.targetContainers.count) {
        _statusKey = @"lc.tapSync.restoredPaused";
        [self changed];
    }
}
- (NSArray *)currentGeometry { return [self currentGeometryWithProblem:NULL]; }
- (NSArray *)currentGeometryWithProblem:(NSString * __autoreleasing *)problem {
    if (problem) *problem = nil;
    if (!self.host.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        self.host.window.windowScene.activationState != UISceneActivationStateForegroundActive ||
        !self.sourceContainer || self.targetContainers.count == 0 ||
        self.host.isAdjustingGridDividers || self.host.isChoosingGridSwap) return nil;
    NSArray *participants = [@[self.sourceContainer] arrayByAddingObjectsFromArray:self.targetContainers];
    NSMutableArray *geometry = [NSMutableArray arrayWithObjects:[NSValue valueWithCGRect:self.host.bounds],
        [NSValue valueWithUIEdgeInsets:self.host.safeAreaInsets], @(self.host.window.windowScene.interfaceOrientation), nil];
    NSArray<DecoratedAppSceneViewController *> *visible = self.host.tapSyncWindows;
    NSString *bundle;
    CGSize sourceSize = CGSizeZero;
    for (NSString *container in participants) {
        if (problem) *problem = container;
        DecoratedAppSceneViewController *window = [self.host windowForContainer:container];
        if (!window || ![visible containsObject:window] || !window.appSceneVC.tapSyncPeer.ready ||
            !CGAffineTransformIsIdentity(window.view.transform) || window.view.alpha < 0.999) return nil;
        if (!bundle) { bundle = window.appSceneVC.bundleId; sourceSize = window.appSceneVC.view.bounds.size; }
        else if (![bundle isEqualToString:window.appSceneVC.bundleId] || !window.appSceneVC.tapSyncPeer.canReplay) return nil;
        CGRect frame = [window.view convertRect:window.view.bounds toView:self.host];
        if (!CGRectContainsRect(CGRectInset(self.host.bounds, -1, -1), frame)) return nil;
        // Every participant must remain visible. Overlapping guest windows are ambiguous to operate together.
        for (DecoratedAppSceneViewController *other in visible) {
            if (other == window) continue;
            CGRect otherFrame = [other.view convertRect:other.view.bounds toView:self.host];
            if (CGRectIntersectsRect(CGRectInset(frame, 1, 1), CGRectInset(otherFrame, 1, 1))) return nil;
        }
        CGSize size = window.appSceneVC.view.bounds.size;
        LCTapSyncSample shape = {0, 0, sourceSize.width, sourceSize.height, 1, 0, 1, 1};
        if (!LCTapSyncCanMap(shape, size.width, size.height, 1)) return nil;
        [geometry addObject:@[container, [NSValue valueWithCGRect:frame],
            [NSValue valueWithCGRect:window.appSceneVC.view.bounds],
            [NSValue valueWithUIEdgeInsets:window.appSceneVC.view.safeAreaInsets], @(window.scaleRatio)]];
    }
    if (problem) *problem = nil;
    return geometry.copy;
}
- (BOOL)canStart { return !self.active && !self.starting && [self currentGeometry] != nil; }
- (BOOL)hasInterruption {
    return !self.active && !self.starting && !self.recovering &&
        ![@[@"lc.tapSync.paused", @"lc.tapSync.chooseWindows", @"lc.tapSync.restoredPaused", @"lc.tapSync.reconnectedPaused"] containsObject:self.statusKey];
}
- (NSString *)statusKeyForContainer:(NSString *)container { return self.interruptionStatusKeys[container] ?: self.statusKey; }
- (void)prepareContainer:(NSString *)container session:(LCTapSyncSession *)session source:(BOOL)source
                 attempt:(NSUInteger)attempt reply:(void (^)(LCTapSyncResult))reply {
    if (self.session != session) return;
    AppSceneViewController *scene = [self.scenes objectForKey:container];
    if (!scene.tapSyncPeer) { reply(LCTapSyncResultUnavailable); return; }
    [scene.tapSyncPeer prepareSession:session.identifier source:source mode:session.mode resumeOnSource:self.resumeOnSource reply:^(LCTapSyncResult result) {
        if (self.session != session) return;
        if (attempt < 3 && (result == LCTapSyncResultSceneInactive || result == LCTapSyncResultWindowNotReady)) {
            [self validateWindows];
            if (self.session != session) return;
            // Hosted scenes can remain inactive after the host dismisses a sheet or returns
            // to the foreground (the same hosting issue handled on PiP restoration).
            // Only a visible participant in an explicit foreground start may be reactivated.
            if (result == LCTapSyncResultSceneInactive && attempt == 0 && scene.usesHostingControllerAPI) {
                [scene setBackgroundNotificationEnabled:YES];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (self.session != session) return;
                [self validateWindows];
                if (self.session == session) [self prepareContainer:container session:session source:source attempt:attempt + 1 reply:reply];
            });
            return;
        }
        reply(result);
    }];
}
- (void)start { [self startPreservingCount:NO]; }
- (void)startPreservingCount:(BOOL)preserveCount {
    if (self.active || self.starting) return;
    [self cancelRecoveryStoppingGuests:YES];
    if (self.sourceContainer && self.targetContainers.count) {
        NSMutableArray *disconnected = [NSMutableArray array];
        for (NSString *container in [@[self.sourceContainer] arrayByAddingObjectsFromArray:self.targetContainers]) {
            if (![self isReadyForContainer:container]) [disconnected addObject:container];
        }
        if (disconnected.count) { [self stopWithResult:LCTapSyncResultUnavailable containers:disconnected]; return; }
        NSMutableArray *unsupported = [NSMutableArray array];
        for (NSString *container in self.targetContainers) if (![self canReplayForContainer:container]) [unsupported addObject:container];
        if (unsupported.count) { [self stopWithResult:LCTapSyncResultUnsupported containers:unsupported]; return; }
    }
    NSString *problem;
    NSArray *geometry = [self currentGeometryWithProblem:&problem];
    if (!geometry) { [self stopWithStatus:@"lc.tapSync.alignWindows" containers:problem ? @[problem] : @[]]; return; }
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:self.sourceContainer targets:self.targetContainers mode:self.mode];
    if (!session) return;
    self.session = session;
    self.geometry = geometry;
    self.inFlightSequence = 0;
    self.deliverySequence = 0;
    [self.inputRevisions removeAllObjects];
    [self.touchingContainers removeAllObjects];
    _interruptedContainers = @[];
    self.interruptionStatusKeys = @{};
    NSMutableDictionary *numbers = [NSMutableDictionary dictionary];
    NSUInteger number = 0;
    for (LCWorkspaceWindow *window in self.availableWindows) numbers[window.dataUUID] = @(++number);
    self.participantNumbers = numbers.copy;
    self.preparation = [[LCTapSyncPreparation alloc] initWithContainers:session.targets];
    if (!preserveCount) _forwardedTapCount = 0;
    _starting = YES;
    _statusKey = @"lc.tapSync.starting";
    [self changed];
    for (NSString *container in session.targets) {
        [self prepareContainer:container session:session source:NO attempt:0 reply:^(LCTapSyncResult result) {
            if (self.session != session) return;
            if (![self.preparation recordResult:result forContainer:container] || self.preparation.pendingContainers.count) return;
            if (self.preparation.failures.count) { [self stopWithPreparationFailures:self.preparation.failures]; return; }
            self.preparation = [[LCTapSyncPreparation alloc] initWithContainers:@[session.source]];
            [self prepareContainer:session.source session:session source:YES attempt:0 reply:^(LCTapSyncResult sourceResult) {
                if (self.session != session) return;
                [self.preparation recordResult:sourceResult forContainer:session.source];
                if (sourceResult != LCTapSyncResultAccepted) { [self stopWithResult:sourceResult containers:@[session.source]]; return; }
                self.preparation = nil;
                [self validateWindows];
                if (self.session != session) return;
                self->_starting = NO;
                self->_active = YES;
                [self resetPerformanceData];
                self->_statusKey = @"lc.tapSync.active";
                [self changed];
                [self sendNext];
            }];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.session == session && self.starting) [self stopWithPreparationFailures:self.preparation.failuresIncludingTimeouts];
    });
}
- (void)receiveTap:(NSDictionary *)tap source:(NSString *)source session:(NSString *)identifier sequence:(uint64_t)sequence {
    LCTapSyncSession *session = self.session;
    if (!session || ![session.identifier isEqualToString:identifier] || ![session.source isEqualToString:source]) return;
    [self validateWindows];
    if (self.session != session) return;
    LCTapSyncResult result = [session enqueue:tap fromSource:source session:identifier sequence:sequence
        now:NSProcessInfo.processInfo.systemUptime];
    if (result != LCTapSyncResultAccepted) { [self stopForEnqueueResult:result source:source]; return; }
    [self recordQueueWithCoalescedMoves:0];
    [self sendNext];
}
- (void)receiveTouch:(NSDictionary *)touch source:(NSString *)source session:(NSString *)identifier sequence:(uint64_t)sequence {
    LCTapSyncSession *session = self.session;
    if (!session || ![session.identifier isEqualToString:identifier] || ![session.source isEqualToString:source]) return;
    NSUInteger coalesced = session.coalescedMoveCount;
    LCTapSyncResult result = [session enqueueTouch:touch fromSource:source session:identifier sequence:sequence
        now:NSProcessInfo.processInfo.systemUptime];
    if (result != LCTapSyncResultAccepted) { [self stopForEnqueueResult:result source:source]; return; }
    [self recordQueueWithCoalescedMoves:session.coalescedMoveCount - coalesced];
    [self sendNext];
}
- (void)receiveTouchFrame:(NSDictionary *)frame source:(NSString *)source session:(NSString *)identifier sequence:(uint64_t)sequence {
    LCTapSyncSession *session = self.session;
    if (!session || ![session.identifier isEqualToString:identifier] || ![session.source isEqualToString:source]) return;
    NSUInteger coalesced = session.coalescedMoveCount;
    LCTapSyncResult result = [session enqueueTouchFrame:frame fromSource:source session:identifier sequence:sequence
        now:NSProcessInfo.processInfo.systemUptime];
    if (result != LCTapSyncResultAccepted) { [self stopForEnqueueResult:result source:source]; return; }
    [self recordQueueWithCoalescedMoves:session.coalescedMoveCount - coalesced];
    [self sendNext];
}
- (void)stopForEnqueueResult:(LCTapSyncResult)result source:(NSString *)source {
    NSArray *affected = result == LCTapSyncResultBusy && self.awaitingReplies.count ? self.awaitingReplies.array : @[source];
    [self stopWithResult:result containers:affected];
}
- (void)sendNext {
    LCTapSyncSession *session = self.session;
    if (!self.active || !session || self.inFlightSequence) return;
    LCTapSyncResult result;
    NSDictionary *next = [session takeNextAtTime:NSProcessInfo.processInfo.systemUptime result:&result];
    if (result != LCTapSyncResultAccepted) { [self stopWithResult:result containers:@[]]; return; }
    if (!next) return;
    LCTouchSyncSample touch = {0};
    LCMultiTouchSyncFrame frame = {0};
    BOOL isTouch = next[@"touch"] != nil;
    BOOL isFrame = next[@"frame"] != nil;
    if ((isTouch && !LCTouchSyncDecode(next[@"touch"], &touch)) || (isFrame && !LCMultiTouchSyncDecode(next[@"frame"], &frame))) {
        [self stopWithResult:LCTapSyncResultInvalidGesture containers:@[session.source]]; return;
    }
    // Layout callbacks also validate geometry. A move does not need another full host window scan.
    if ((!isTouch && !isFrame) || (isTouch && touch.phase == LCTouchSyncPhaseBegan) || (isFrame && LCMultiTouchSyncHasBoundary(frame))) {
        [self validateWindows];
        if (self.session != session) return;
    }
    if (self.deliverySequence == UINT64_MAX) { [self pause]; return; }
    // Coalescing may skip source move numbers; recipients still receive a contiguous delivery sequence.
    uint64_t sequence = ++self.deliverySequence;
    self.inFlightSequence = sequence;
    BOOL completedAction = isFrame ? [next[@"completed"] boolValue] : !isTouch || touch.phase == LCTouchSyncPhaseEnded;
    self.awaitingReplies = [NSMutableOrderedSet orderedSetWithArray:session.targets];
    BOOL measure = self.collectsPerformanceData;
    NSUInteger measurementGeneration = self.performanceGeneration;
    NSTimeInterval sentAt = measure ? NSProcessInfo.processInfo.systemUptime : 0;
    self.replyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.replyTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.replyTimer, ^{
        if (weakSelf.session == session && weakSelf.inFlightSequence == sequence) {
            [weakSelf stopWithStatus:@"lc.tapSync.tooSlow" containers:weakSelf.awaitingReplies.array];
        }
    });
    dispatch_resume(self.replyTimer);
    __block NSUInteger remaining = session.targets.count;
    for (NSString *container in session.targets) {
        void (^receiveReply)(LCTapSyncResult) = ^(LCTapSyncResult reply) {
            if (self.session != session || self.inFlightSequence != sequence) return;
            if (reply == LCTapSyncResultSuspended && self.resumeOnSource) {
                [self beginRecovery:LCTapSyncRecoveryFollowerInput containers:@[container]];
                return;
            }
            if (reply != LCTapSyncResultAccepted) { [self stopWithResult:reply containers:@[container]]; return; }
            [self.awaitingReplies removeObject:container];
            if (--remaining != 0) return;
            self.inFlightSequence = 0;
            dispatch_source_cancel(self.replyTimer);
            self.replyTimer = nil;
            if (measure && self.collectsPerformanceData && measurementGeneration == self.performanceGeneration) {
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                LCPerformanceRecordResponse(&self->_responseHistory, now, (now - sentAt) * 1000);
                self.measuredPackets++;
            }
            if (completedAction) {
                self->_forwardedTapCount += 1;
                [self changed];
            }
            [self sendNext];
        };
        LCTapSyncPeer *peer = [self.scenes objectForKey:container].tapSyncPeer;
        if (isFrame) [peer replayTouchFrame:next[@"frame"] session:session.identifier sequence:sequence reply:receiveReply];
        else if (isTouch) [peer replayTouch:next[@"touch"] session:session.identifier sequence:sequence reply:receiveReply];
        else [peer replayTap:next[@"tap"] session:session.identifier sequence:sequence reply:receiveReply];
    }
}
- (NSString *)statusKeyForResult:(LCTapSyncResult)result {
    NSString *status = @"lc.tapSync.unavailable";
    switch (result) {
        case LCTapSyncResultUnsupported: status = @"lc.tapSync.unsupported"; break;
        case LCTapSyncResultGeometryChanged: status = @"lc.tapSync.layoutChanged"; break;
        case LCTapSyncResultBusy: status = @"lc.tapSync.interrupted"; break;
        case LCTapSyncResultExpired: status = @"lc.tapSync.tooSlow"; break;
        case LCTapSyncResultStopped: status = @"lc.tapSync.paused"; break;
        case LCTapSyncResultInvalidGesture: status = @"lc.tapSync.gestureInterrupted"; break;
        case LCTapSyncResultMultipleTouches: status = @"lc.tapSync.multipleTouches"; break;
        case LCTapSyncResultTooManyTouches: status = @"lc.tapSync.tooManyTouches"; break;
        case LCTapSyncResultSceneInactive: status = @"lc.tapSync.sceneInactive"; break;
        case LCTapSyncResultWindowCovered: status = @"lc.tapSync.windowCovered"; break;
        case LCTapSyncResultWindowNotReady: status = @"lc.tapSync.windowNotReady"; break;
        case LCTapSyncResultKeyboardVisible: status = @"lc.tapSync.keyboardVisible"; break;
        case LCTapSyncResultPhysicalTouch: status = @"lc.tapSync.physicalTouch"; break;
        case LCTapSyncResultPreparationTimedOut: status = @"lc.tapSync.preparationTimedOut"; break;
        case LCTapSyncResultSuspended: status = @"lc.tapSync.waitingForSource"; break;
        default: break;
    }
    return status;
}
- (void)stopWithResult:(LCTapSyncResult)result containers:(NSArray<NSString *> *)containers {
    if (result == LCTapSyncResultGeometryChanged && [self shouldRecoverForRotation]) {
        [self beginRecovery:LCTapSyncRecoveryRotation containers:containers];
        return;
    }
    [self stopWithStatus:[self statusKeyForResult:result] containers:containers];
}
- (void)stopWithPreparationFailures:(NSDictionary<NSString *, NSNumber *> *)failures {
    if (!self.session) return;
    NSMutableArray *containers = [NSMutableArray array];
    NSMutableDictionary *reasons = [NSMutableDictionary dictionary];
    for (NSString *container in [@[self.session.source] arrayByAddingObjectsFromArray:self.session.targets]) {
        if (!failures[container]) continue;
        [containers addObject:container];
        reasons[container] = [self statusKeyForResult:[failures[container] integerValue]];
    }
    NSSet *distinct = [NSSet setWithArray:reasons.allValues];
    NSString *status = distinct.count == 1 ? distinct.anyObject : @"lc.tapSync.startFailed";
    [self stopWithStatus:status containers:containers reasons:reasons];
}
- (void)stopWithStatus:(NSString *)status containers:(NSArray<NSString *> *)containers {
    [self stopWithStatus:status containers:containers reasons:@{}];
}
- (void)stopWithStatus:(NSString *)status containers:(NSArray<NSString *> *)containers reasons:(NSDictionary<NSString *, NSString *> *)reasons {
    [self cancelRecoveryStoppingGuests:YES];
    _interruptedContainers = containers.copy ?: @[];
    self.interruptionStatusKeys = reasons.copy;
    LCTapSyncSession *session = self.session;
    self.session = nil;
    self.preparation = nil;
    [session invalidate];
    self.geometry = nil;
    self.inFlightSequence = 0;
    if (self.replyTimer) dispatch_source_cancel(self.replyTimer);
    self.replyTimer = nil;
    self.awaitingReplies = nil;
    [self.inputRevisions removeAllObjects];
    [self.touchingContainers removeAllObjects];
    _active = NO;
    _starting = NO;
    _statusKey = status;
    if (session) {
        [self resetPerformanceData];
        for (NSString *container in [@[session.source] arrayByAddingObjectsFromArray:session.targets]) {
            [[self.scenes objectForKey:container].tapSyncPeer stopSession:session.identifier];
        }
    }
    [self changed];
}
- (void)pause { [self stopWithStatus:@"lc.tapSync.paused" containers:@[]]; }
- (void)pauseForWindowChange {
    if (self.session || self.recovering) [self stopWithStatus:@"lc.tapSync.layoutChanged" containers:@[]];
}
- (void)pauseForChangeToContainer:(NSString *)container {
    if (self.session || self.recovering) [self stopWithStatus:@"lc.tapSync.layoutChanged" containers:@[container]];
}
- (BOOL)shouldRecoverForRotation {
    return self.active && self.session && self.autoResumeAfterRotation && [self hostRotatedSinceGeometry:self.geometry];
}
- (BOOL)hostIsAnimatingRotation {
    id<UIViewControllerTransitionCoordinator> transition = self.host.window.rootViewController.transitionCoordinator;
    if (!transition) return NO;
    CGAffineTransform transform = transition.targetTransform;
    return fabs(atan2(transform.b, transform.a)) > 0.01;
}
- (BOOL)hostRotatedSinceGeometry:(NSArray *)geometry {
    // UIKit can update bounds/insets before interfaceOrientation. The public
    // transition transform identifies that rotation without treating resizing,
    // Stage Manager or orientation-locked device movement as a rotation.
    return geometry.count >= 3 && self.host.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        self.host.window.windowScene.activationState == UISceneActivationStateForegroundActive &&
        self.host.window.windowScene.interfaceOrientation != UIInterfaceOrientationUnknown &&
        ([geometry[2] integerValue] != self.host.window.windowScene.interfaceOrientation || self.hostIsAnimatingRotation);
}
- (void)physicalInputForContainer:(NSString *)container session:(NSString *)identifier revision:(uint64_t)revision
                        touching:(BOOL)touching began:(BOOL)began timestamp:(NSTimeInterval)timestamp {
    if (!isfinite(timestamp) || timestamp < 0 || (began && !touching)) return;
    if ([self.recoverySession.identifier isEqualToString:identifier]) {
        BOOL followerReturn = began && touching && self.resumeOnSource && [self.recoverySession.targets containsObject:container] &&
            self.recovery.reason == LCTapSyncRecoveryRotation;
        if ([self.recovery recordInputForContainer:container revision:revision touching:touching began:began atTime:timestamp]) {
            if (touching && !self.resumeOnSource && [self.recoverySession.targets containsObject:container]) {
                [self stopWithResult:LCTapSyncResultPhysicalTouch containers:@[container]];
                return;
            }
            if (followerReturn) {
                [self.recovery waitForSourceReturnAfter:timestamp];
                _statusKey = @"lc.tapSync.waitingForSource";
                _interruptedContainers = @[container];
                [self changed];
            }
            [self scheduleRecoveryCheck];
        }
        return;
    }
    if (![self.session.identifier isEqualToString:identifier] || ![self isParticipant:container]) return;
    NSNumber *previous = self.inputRevisions[container];
    if (previous && revision <= previous.unsignedLongLongValue) return;
    self.inputRevisions[container] = @(revision);
    if (touching) [self.touchingContainers addObject:container]; else [self.touchingContainers removeObject:container];
    if (self.resumeOnSource && touching && [self.session.targets containsObject:container]) {
        if (self.active) [self beginRecovery:LCTapSyncRecoveryFollowerInput containers:@[container]];
        else if (self.starting) [self stopWithResult:LCTapSyncResultPhysicalTouch containers:@[container]];
    }
}
- (void)beginRecovery:(LCTapSyncRecoveryReason)reason containers:(NSArray<NSString *> *)containers {
    LCTapSyncSession *session = self.session;
    if (!session || !self.active) return;
    LCTapSyncRecovery *recovery = [[LCTapSyncRecovery alloc] initWithSource:session.source targets:session.targets reason:reason
                                                                afterTime:NSProcessInfo.processInfo.systemUptime];
    for (NSString *container in self.inputRevisions) {
        [recovery recordInputForContainer:container revision:self.inputRevisions[container].unsignedLongLongValue
                                touching:[self.touchingContainers containsObject:container] began:NO atTime:0];
    }
    self.recovery = recovery;
    self.recoverySession = session;
    self.recoveryAllowsGeometryChange = reason == LCTapSyncRecoveryRotation;
    self.recoveryReadyDeadline = 0;
    self.session = nil;
    self.preparation = nil;
    [session invalidate];
    self.inFlightSequence = 0;
    if (self.replyTimer) dispatch_source_cancel(self.replyTimer);
    self.replyTimer = nil;
    self.awaitingReplies = nil;
    _active = NO;
    _starting = NO;
    _interruptedContainers = containers.copy;
    self.interruptionStatusKeys = @{};
    _statusKey = reason == LCTapSyncRecoveryRotation ? @"lc.tapSync.waitingForRotation" : @"lc.tapSync.waitingForSource";
    [self resetPerformanceData];
    [self changed];
    for (NSString *container in [@[session.source] arrayByAddingObjectsFromArray:session.targets]) {
        [[self.scenes objectForKey:container].tapSyncPeer suspendSession:session.identifier reply:^(LCTapSyncResult result, BOOL touching, uint64_t revision) {
            if (self.recovery != recovery) return;
            if (result != LCTapSyncResultAccepted) { [self stopWithResult:result containers:@[container]]; return; }
            if ([recovery acknowledgeContainer:container revision:revision touching:touching]) [self scheduleRecoveryCheck];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.recovery == recovery && recovery.pendingContainers.count) {
            [self stopWithResult:LCTapSyncResultPreparationTimedOut containers:recovery.pendingContainers];
        }
    });
}
- (void)cancelRecoveryStoppingGuests:(BOOL)stop {
    LCTapSyncSession *session = self.recoverySession;
    [self.recovery invalidate];
    self.recovery = nil;
    self.recoverySession = nil;
    self.recoveryCheckScheduled = NO;
    self.recoveryAllowsGeometryChange = NO;
    self.recoveryReadyDeadline = 0;
    if (stop && session) {
        for (NSString *container in [@[session.source] arrayByAddingObjectsFromArray:session.targets]) {
            [[self.scenes objectForKey:container].tapSyncPeer stopSession:session.identifier];
        }
    }
}
- (void)scheduleRecoveryCheck {
    LCTapSyncRecovery *recovery = self.recovery;
    if (!recovery.canResume) { self.recoveryReadyDeadline = 0; return; }
    if (self.recoveryCheckScheduled) return;
    if (!self.recoveryReadyDeadline) self.recoveryReadyDeadline = NSProcessInfo.processInfo.systemUptime + 3;
    self.recoveryCheckScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.recovery != recovery) return;
        self.recoveryCheckScheduled = NO;
        if (!recovery.canResume) { self.recoveryReadyDeadline = 0; return; }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSArray *geometry = self.hostIsAnimatingRotation ? nil : self.currentGeometry;
        if (geometry && !self.recoveryAllowsGeometryChange && ![geometry isEqual:self.geometry]) {
            if (self.autoResumeAfterRotation && [self hostRotatedSinceGeometry:self.geometry]) self.recoveryAllowsGeometryChange = YES;
            else { [self stopWithStatus:@"lc.tapSync.layoutChanged" containers:@[]]; return; }
        }
        if ([recovery layoutIsStable:geometry atTime:now]) {
            [self startPreservingCount:YES];
        } else if (now >= self.recoveryReadyDeadline) {
            [self stopWithStatus:@"lc.tapSync.alignWindows" containers:@[]];
        } else [self scheduleRecoveryCheck];
    });
}
- (void)validateWindows {
    if (self.session) {
        NSString *problem;
        NSArray *current = [self currentGeometryWithProblem:&problem];
        if (![self.geometry isEqual:current]) {
            NSMutableArray *affected = [NSMutableArray array];
            if (problem) [affected addObject:problem];
            else if (current.count == self.geometry.count) {
                for (NSUInteger i = 3; i < current.count; i++) {
                    if (![current[i] isEqual:self.geometry[i]]) [affected addObject:current[i][0]];
                }
            }
            if ([self shouldRecoverForRotation]) [self beginRecovery:LCTapSyncRecoveryRotation containers:affected];
            else [self stopWithStatus:@"lc.tapSync.layoutChanged" containers:affected];
        }
    }
    if (self.recovering) {
        if (!self.recoveryAllowsGeometryChange && self.autoResumeAfterRotation && [self hostRotatedSinceGeometry:self.geometry]) {
            self.recoveryAllowsGeometryChange = YES;
        }
        [self scheduleRecoveryCheck];
    }
    NSMutableArray *presentation = [NSMutableArray array];
    for (DecoratedAppSceneViewController *window in self.host.tapSyncWindows) {
        [presentation addObject:@[window.appSceneVC.dataUUID, [NSValue valueWithCGRect:window.view.frame],
            [NSValue valueWithCGRect:window.appSceneVC.view.bounds], @(window.scaleRatio)]];
    }
    if (![self.lastWindowPresentation isEqual:presentation]) {
        self.lastWindowPresentation = presentation.copy;
        [self changed];
    }
}
- (void)hostWillResignActive:(NSNotification *)note {
    if (self.session || self.recovering) [self stopWithStatus:@"lc.tapSync.backgroundPaused" containers:@[]];
}
- (void)hostDidBecomeActive:(NSNotification *)note {
    [self validateWindows];
    [self changed];
}
- (void)setCollectsPerformanceData:(BOOL)collectsPerformanceData {
    if (_collectsPerformanceData == collectsPerformanceData) return;
    _collectsPerformanceData = collectsPerformanceData;
    [self resetPerformanceData];
}
- (void)resetPerformanceData {
    self.performanceGeneration++;
    _responseHistory = (LCPerformanceResponseHistory){0};
    self.measuredPackets = 0;
    self.measuredCoalescedMoves = 0;
    self.measuredQueuePeak = 0;
}
- (void)recordQueueWithCoalescedMoves:(NSUInteger)count {
    if (!self.collectsPerformanceData) return;
    self.measuredCoalescedMoves += count;
    self.measuredQueuePeak = MAX(self.measuredQueuePeak, self.session.pendingCount);
}
- (NSDictionary *)performanceSnapshot {
    double p50, p95;
    unsigned count = LCPerformanceResponsePercentiles(&_responseHistory, NSProcessInfo.processInfo.systemUptime, &p50, &p95);
    NSMutableDictionary *snapshot = [@{@"packets": @(self.measuredPackets), @"coalesced": @(self.measuredCoalescedMoves),
        @"queuePeak": @(self.measuredQueuePeak), @"pending": @(self.session.pendingCount), @"inFlight": @(self.inFlightSequence != 0),
        @"responseSamples": @(count), @"mode": @(self.mode), @"active": @(self.active), @"targets": @(self.targetContainers.count),
        @"epoch": @(self.performanceGeneration)} mutableCopy];
    if (count) { snapshot[@"responseP50Ms"] = @(p50); snapshot[@"responseP95Ms"] = @(p95); }
    return snapshot.copy;
}
@end
