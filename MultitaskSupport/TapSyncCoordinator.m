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

// A delayed acknowledgment can follow input that was delivered while fresh.
// Give it more time without extending the separate 750 ms replay freshness limit.
static NSTimeInterval const LCTapSyncReplyTimeout = 3;
static NSTimeInterval const LCTapSyncPreparationTimeout = 5;

@interface LCTapSyncCoordinator ()
@property(nonatomic) NSMapTable<NSString *, AppSceneViewController *> *scenes;
@property(nonatomic) LCTapSyncSelectionStore *selectionStore;
@property(nonatomic) LCTapSyncSession *session;
@property(nonatomic) LCTapSyncPreparation *preparation;
@property(nonatomic) NSTimeInterval preparationDeadline;
@property(nonatomic, weak) UIWindowScene *sessionHostScene;
@property(nonatomic) BOOL hostInactive;
@property(nonatomic) NSUInteger hostActivityGeneration;
@property(nonatomic) LCTapSyncRecovery *recovery;
@property(nonatomic) LCTapSyncSession *recoverySession;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *inputRevisions;
@property(nonatomic) NSMutableSet<NSString *> *touchingContainers;
@property(nonatomic) BOOL recoveryCheckScheduled;
@property(nonatomic) BOOL recoveryAllowsGeometryChange;
@property(nonatomic) NSTimeInterval recoveryReadyDeadline;
@property(nonatomic) uint64_t returnGestureRevision;
@property(nonatomic) NSTimeInterval returnGestureBeganAt;
@property(nonatomic, copy) NSString *resumingSourceSession;
@property(nonatomic) uint64_t resumingSourceRevision;
@property(nonatomic) NSTimeInterval resumingSourceBeganAt;
@property(nonatomic) BOOL awaitingSourceReturn;
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
- (void)physicalInputForContainer:(NSString *)container session:(NSString *)identifier revision:(uint64_t)revision touching:(BOOL)touching began:(BOOL)began timestamp:(NSTimeInterval)timestamp returnRevision:(uint64_t)returnRevision;
- (void)beginRecovery:(LCTapSyncRecoveryReason)reason containers:(NSArray<NSString *> *)containers;
- (void)cancelRecoveryStoppingGuests:(BOOL)stop;
- (void)scheduleRecoveryCheck;
- (BOOL)shouldRecoverForRotation;
- (BOOL)hostRotatedSinceGeometry:(NSArray *)geometry;
- (BOOL)hostIsAnimatingRotation;
- (void)startPreservingCount:(BOOL)preserveCount;
- (void)finishStartingSession:(LCTapSyncSession *)session;
- (BOOL)hostIsForegroundActive;
- (BOOL)hostHasLostForeground;
- (void)hostWillResignActive:(nullable NSNotification *)note;
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
        // The foreground-resume prototype was withdrawn after device failures.
        // Remove only its saved switch; group, mode and remaining options survive.
        if ([NSUserDefaults.lcSharedDefaults objectForKey:@"LCTapSyncAutoResumeOnForeground"]) {
            [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCTapSyncAutoResumeOnForeground"];
        }
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
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostDidEnterBackground:)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostSceneWillDeactivate:)
                                                   name:UISceneWillDeactivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostSceneDidEnterBackground:)
                                                   name:UISceneDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostSceneDidActivate:)
                                                   name:UISceneDidActivateNotification object:nil];
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
    scene.tapSyncPeer.didReceiveSourceReturn = ^(NSArray<NSDictionary *> *packets, NSString *session) {
        [weakSelf receiveSourceReturn:packets source:weakScene.dataUUID session:session];
    };
    scene.tapSyncPeer.didInterrupt = ^(NSString *session, LCTapSyncResult reason) {
        LCTapSyncCoordinator *coordinator = weakSelf;
        if ([coordinator.resumingSourceSession isEqualToString:session] && [coordinator.sourceContainer isEqualToString:weakScene.dataUUID]) {
            [coordinator stopWithResult:reason containers:@[weakScene.dataUUID]];
        } else if ([coordinator.recoverySession.identifier isEqualToString:session] && [coordinator isParticipant:weakScene.dataUUID]) {
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
    scene.tapSyncPeer.didChangePhysicalInput = ^(NSString *session, uint64_t revision, BOOL touching, BOOL began, NSTimeInterval timestamp, uint64_t returnRevision) {
        [weakSelf physicalInputForContainer:weakScene.dataUUID session:session revision:revision touching:touching began:began timestamp:timestamp returnRevision:returnRevision];
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
- (BOOL)syncReturnGesture { return [NSUserDefaults.lcSharedDefaults boolForKey:@"LCTapSyncSyncReturnGesture"]; }
- (void)setSyncReturnGesture:(BOOL)value {
    if (value == self.syncReturnGesture) return;
    [self pause];
    [NSUserDefaults.lcSharedDefaults setBool:value forKey:@"LCTapSyncSyncReturnGesture"];
    [self changed];
}
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
    if (self.hostInactive || ![self hostIsForegroundActive] ||
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
    void (^completed)(LCTapSyncResult) = ^(LCTapSyncResult result) {
        if (self.session != session) return;
        BOOL canRetry = self.resumingSourceSession ? attempt < 3 :
            NSProcessInfo.processInfo.systemUptime + 0.2 < self.preparationDeadline;
        if (canRetry && (result == LCTapSyncResultSceneInactive || result == LCTapSyncResultWindowNotReady)) {
            [self validateWindows];
            if (self.session != session) return;
            // Hosted scenes can remain inactive after the host dismisses a sheet or returns
            // to the foreground (the same hosting issue handled on PiP restoration).
            // Only a visible participant in a fresh foreground check may be reactivated.
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
    };
    if (source && self.resumingSourceSession) {
        [scene.tapSyncPeer resumeSourceSession:session.identifier previousSession:self.resumingSourceSession
                                inputRevision:self.resumingSourceRevision reply:completed];
    } else {
        [scene.tapSyncPeer prepareSession:session.identifier source:source mode:session.mode resumeOnSource:self.resumeOnSource
                         syncReturnGesture:self.syncReturnGesture reply:completed];
    }
}
- (void)start { [self startPreservingCount:NO]; }
- (void)startPreservingCount:(BOOL)preserveCount {
    if (self.active || self.starting) return;
    NSString *previousSource = preserveCount && self.resumeOnSource && self.syncReturnGesture &&
        self.returnGestureRevision && self.recovery.canResumeWithSourceGesture ? self.recoverySession.identifier : nil;
    LCTapSyncSession *previousSession = self.recoverySession;
    uint64_t returnRevision = self.returnGestureRevision;
    NSTimeInterval returnBeganAt = self.returnGestureBeganAt;
    [self cancelRecoveryStoppingGuests:previousSource == nil];
    self.resumingSourceSession = previousSource;
    self.resumingSourceRevision = previousSource ? returnRevision : 0;
    self.resumingSourceBeganAt = previousSource ? returnBeganAt : 0;
    self.awaitingSourceReturn = previousSource != nil;
    if (previousSource) {
        for (NSString *container in previousSession.targets) {
            [[self.scenes objectForKey:container].tapSyncPeer stopSession:previousSource];
        }
    }
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
    if (!session) { [self stopWithResult:LCTapSyncResultInvalidGesture containers:@[]]; return; }
    self.session = session;
    self.sessionHostScene = self.host.window.windowScene;
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
    self.preparationDeadline = NSProcessInfo.processInfo.systemUptime + LCTapSyncPreparationTimeout;
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
                [self finishStartingSession:session];
            }];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCTapSyncPreparationTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.session != session || !self.starting) return;
        if (self.preparation) [self stopWithPreparationFailures:self.preparation.failuresIncludingTimeouts];
        else [self stopWithResult:LCTapSyncResultPreparationTimedOut containers:@[session.source]];
    });
}
- (void)finishStartingSession:(LCTapSyncSession *)session {
    // The return payload and the RPC reply can arrive in either order. Do not
    // replay its first down until both the capture and every preparation succeed.
    if (self.session != session || !self.starting || self.preparation || self.awaitingSourceReturn) return;
    [self validateWindows];
    if (self.session != session) return;
    _starting = NO;
    _active = YES;
    self.preparationDeadline = 0;
    self.resumingSourceSession = nil;
    self.resumingSourceRevision = 0;
    self.resumingSourceBeganAt = 0;
    [self resetPerformanceData];
    _statusKey = @"lc.tapSync.active";
    [self changed];
    [self sendNext];
}
- (void)receiveSourceReturn:(NSArray<NSDictionary *> *)packets source:(NSString *)source session:(NSString *)identifier {
    LCTapSyncSession *session = self.session;
    if (!session || ![session.identifier isEqualToString:identifier] || ![session.source isEqualToString:source]) return;
    if (!self.awaitingSourceReturn || !self.starting || !self.resumingSourceSession) {
        [self stopWithResult:LCTapSyncResultInvalidGesture containers:@[source]]; return;
    }
    [self validateWindows];
    if (self.session != session) return;
    LCTapSyncResult result = [session enqueueSourceReturn:packets fromSource:source session:identifier now:NSProcessInfo.processInfo.systemUptime];
    if (result != LCTapSyncResultAccepted) { [self stopForEnqueueResult:result source:source]; return; }
    self.awaitingSourceReturn = NO;
    [self finishStartingSession:session];
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
    dispatch_source_set_timer(self.replyTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCTapSyncReplyTimeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.replyTimer, ^{
        if (weakSelf.session == session && weakSelf.inFlightSequence == sequence) {
            if ([weakSelf hostHasLostForeground]) [weakSelf hostWillResignActive:nil];
            else [weakSelf stopWithStatus:@"lc.tapSync.tooSlow" containers:weakSelf.awaitingReplies.array];
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
        case LCTapSyncResultExpired: status = @"lc.tapSync.expiredInput"; break;
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
    // A guest can report inactivity before the host receives its lifecycle note.
    // Attribute actual host inactivity to the whole-group foreground pause.
    if (result == LCTapSyncResultSceneInactive && self.active && [self hostHasLostForeground]) {
        [self hostWillResignActive:nil];
        return;
    }
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
    if (self.resumingSourceSession) {
        [[self.scenes objectForKey:self.sourceContainer].tapSyncPeer stopSession:self.resumingSourceSession];
        self.resumingSourceSession = nil;
        self.resumingSourceRevision = 0;
        self.resumingSourceBeganAt = 0;
    }
    _interruptedContainers = containers.copy ?: @[];
    self.interruptionStatusKeys = reasons.copy;
    LCTapSyncSession *session = self.session;
    self.session = nil;
    self.sessionHostScene = nil;
    self.preparation = nil;
    self.preparationDeadline = 0;
    self.awaitingSourceReturn = NO;
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
                        touching:(BOOL)touching began:(BOOL)began timestamp:(NSTimeInterval)timestamp returnRevision:(uint64_t)returnRevision {
    if (!isfinite(timestamp) || timestamp < 0 || (began && !touching)) return;
    if ([self.resumingSourceSession isEqualToString:identifier]) {
        if ([container isEqualToString:self.sourceContainer]) {
            if (revision < self.resumingSourceRevision) return;
            if (returnRevision != self.resumingSourceRevision) [self stopWithStatus:@"lc.tapSync.gestureInterrupted" containers:@[container]];
        } else if ([self.session.targets containsObject:container] && began && timestamp > self.resumingSourceBeganAt) {
            // A follower can send its last old-session event while its new
            // preparation is pending. A newer operation cancels this return.
            [self stopWithResult:LCTapSyncResultPhysicalTouch containers:@[container]];
        }
        return;
    }
    if ([self.recoverySession.identifier isEqualToString:identifier]) {
        BOOL followerReturn = began && touching && self.resumeOnSource && [self.recoverySession.targets containsObject:container] &&
            self.recovery.reason == LCTapSyncRecoveryRotation;
        if ([self.recovery recordInputForContainer:container revision:revision touching:touching began:began atTime:timestamp]) {
            if ([container isEqualToString:self.sourceContainer]) {
                if (returnRevision != self.returnGestureRevision) self.returnGestureBeganAt = returnRevision && began ? timestamp : 0;
                self.returnGestureRevision = returnRevision;
            }
            if (began && touching && [self.recoverySession.targets containsObject:container]) {
                [[self.scenes objectForKey:self.sourceContainer].tapSyncPeer discardSourceReturn:identifier beforeTime:timestamp];
            }
            if (touching && !self.resumeOnSource && [self.recoverySession.targets containsObject:container]) {
                [self stopWithResult:LCTapSyncResultPhysicalTouch containers:@[container]];
                return;
            }
            if (followerReturn) {
                [self.recovery waitForSourceReturnAfter:timestamp];
                _statusKey = self.syncReturnGesture ? @"lc.tapSync.waitingForFirstReturn" : @"lc.tapSync.waitingForSource";
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
    self.returnGestureRevision = 0;
    self.returnGestureBeganAt = 0;
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
    _statusKey = reason == LCTapSyncRecoveryRotation ? @"lc.tapSync.waitingForRotation" :
        self.syncReturnGesture ? @"lc.tapSync.waitingForFirstReturn" : @"lc.tapSync.waitingForSource";
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
    self.returnGestureRevision = 0;
    self.returnGestureBeganAt = 0;
    if (stop && session) {
        for (NSString *container in [@[session.source] arrayByAddingObjectsFromArray:session.targets]) {
            [[self.scenes objectForKey:container].tapSyncPeer stopSession:session.identifier];
        }
    }
}
- (void)scheduleRecoveryCheck {
    LCTapSyncRecovery *recovery = self.recovery;
    BOOL allowSourceGesture = self.resumeOnSource && self.syncReturnGesture && self.returnGestureRevision && recovery.sourceHasReturned;
    if (!(allowSourceGesture ? recovery.canResumeWithSourceGesture : recovery.canResume)) { self.recoveryReadyDeadline = 0; return; }
    if (allowSourceGesture && !self.recoveryAllowsGeometryChange && !self.hostIsAnimatingRotation) {
        // A returning gesture can prepare immediately when the running group's
        // geometry is unchanged. Rotation still needs the normal settle check.
        NSArray *geometry = self.currentGeometry;
        if (geometry && [geometry isEqual:self.geometry]) { [self startPreservingCount:YES]; return; }
    }
    if (self.recoveryCheckScheduled) return;
    if (!self.recoveryReadyDeadline) self.recoveryReadyDeadline = NSProcessInfo.processInfo.systemUptime + 3;
    self.recoveryCheckScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.recovery != recovery) return;
        self.recoveryCheckScheduled = NO;
        BOOL allowSourceGesture = self.resumeOnSource && self.syncReturnGesture && self.returnGestureRevision && recovery.sourceHasReturned;
        if (!(allowSourceGesture ? recovery.canResumeWithSourceGesture : recovery.canResume)) { self.recoveryReadyDeadline = 0; return; }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSArray *geometry = self.hostIsAnimatingRotation ? nil : self.currentGeometry;
        if (geometry && !self.recoveryAllowsGeometryChange && ![geometry isEqual:self.geometry]) {
            if (self.autoResumeAfterRotation && [self hostRotatedSinceGeometry:self.geometry]) self.recoveryAllowsGeometryChange = YES;
            else { [self stopWithStatus:@"lc.tapSync.layoutChanged" containers:@[]]; return; }
        }
        if ([recovery layoutIsStable:geometry atTime:now allowSourceGesture:allowSourceGesture]) {
            [self startPreservingCount:YES];
        } else if (now >= self.recoveryReadyDeadline) {
            [self stopWithStatus:@"lc.tapSync.alignWindows" containers:@[]];
        } else [self scheduleRecoveryCheck];
    });
}
- (void)validateWindows {
    if ((self.session || self.recovering) && [self hostHasLostForeground]) {
        [self hostWillResignActive:nil];
        return;
    }
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
    if (self.recovery) {
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
- (BOOL)hostIsForegroundActive {
    UIWindowScene *scene = self.host.window.windowScene;
    return scene && UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        scene.activationState == UISceneActivationStateForegroundActive;
}
- (BOOL)hostHasLostForeground {
    UIWindowScene *scene = self.host.window.windowScene ?: self.sessionHostScene;
    return self.hostInactive || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (scene && scene.activationState != UISceneActivationStateForegroundActive);
}
- (void)hostWillResignActive:(NSNotification *)note {
    self.hostInactive = YES;
    self.hostActivityGeneration++;
    // Application and scene notifications may both arrive for the same
    // departure. Cancel once and leave the group paused until explicit Resume.
    if (self.session || self.recovering) [self stopWithStatus:@"lc.tapSync.backgroundPaused" containers:@[]];
}
- (void)hostDidEnterBackground:(NSNotification *)note {
    [self hostWillResignActive:note];
}
- (void)hostDidBecomeActive:(NSNotification *)note {
    // Clear the notification latch, not the pause. Manual start still requires
    // this host's actual application and scene states to be foreground-active.
    self.hostInactive = NO;
    [self validateWindows];
    // App and scene activation snapshots can lag each other's notification.
    // Recheck once on the main queue, bound to this departure so a later resign
    // cannot be undone by an earlier activation callback.
    NSUInteger generation = self.hostActivityGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.hostActivityGeneration || ![self hostIsForegroundActive]) return;
        self.hostInactive = NO;
        [self validateWindows];
        [self changed];
    });
    [self changed];
}
- (BOOL)isHostSceneNotification:(NSNotification *)note {
    UIWindowScene *scene = self.host.window.windowScene ?: self.sessionHostScene;
    return scene && note.object == scene;
}
- (void)hostSceneWillDeactivate:(NSNotification *)note {
    if ([self isHostSceneNotification:note]) [self hostWillResignActive:note];
}
- (void)hostSceneDidEnterBackground:(NSNotification *)note {
    if ([self isHostSceneNotification:note]) [self hostDidEnterBackground:note];
}
- (void)hostSceneDidActivate:(NSNotification *)note {
    if ([self isHostSceneNotification:note]) [self hostDidBecomeActive:note];
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
        @"epoch": @(self.performanceGeneration), @"statusKey": self.statusKey} mutableCopy];
    if (count) { snapshot[@"responseP50Ms"] = @(p50); snapshot[@"responseP95Ms"] = @(p95); }
    return snapshot.copy;
}
@end
