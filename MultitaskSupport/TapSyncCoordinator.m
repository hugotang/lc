#import "TapSyncCoordinator.h"
#import "TapSyncSession.h"
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

NSNotificationName const LCTapSyncDidChangeNotification = @"LCTapSyncDidChange";

@interface LCTapSyncCoordinator ()
@property(nonatomic) NSMapTable<NSString *, AppSceneViewController *> *scenes;
@property(nonatomic) LCTapSyncSession *session;
@property(nonatomic) NSArray *geometry;
@property(nonatomic) uint64_t inFlightSequence;
@property(nonatomic) NSArray *lastWindowPresentation;
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
        _targetContainers = @[];
        _statusKey = @"lc.tapSync.chooseWindows";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostWillResignActive:)
                                                   name:UIApplicationWillResignActiveNotification object:nil];
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
            [coordinator stopWithStatus:@"lc.tapSync.unavailable"];
        }
        [coordinator changed];
    };
    scene.tapSyncPeer.didReceiveTap = ^(NSDictionary *tap, NSString *session, uint64_t sequence) {
        [weakSelf receiveTap:tap source:weakScene.dataUUID session:session sequence:sequence];
    };
    scene.tapSyncPeer.didInterrupt = ^(NSString *session, LCTapSyncResult reason) {
        LCTapSyncCoordinator *coordinator = weakSelf;
        if ([coordinator.session.identifier isEqualToString:session] && [coordinator isParticipant:weakScene.dataUUID]) {
            [coordinator stopWithResult:reason];
        }
    };
    [self changed];
}
- (void)unregisterScene:(AppSceneViewController *)scene {
    if ([self.scenes objectForKey:scene.dataUUID] != scene) return;
    if ([self isParticipant:scene.dataUUID]) [self stopWithStatus:@"lc.tapSync.unavailable"];
    [self.scenes removeObjectForKey:scene.dataUUID];
    [scene.tapSyncPeer invalidate];
    [self changed];
}
- (BOOL)isParticipant:(NSString *)container {
    return self.session && ([self.session.source isEqualToString:container] || [self.session.targets containsObject:container]);
}
- (BOOL)isReadyForContainer:(NSString *)container { return [self.scenes objectForKey:container].tapSyncPeer.ready; }
- (BOOL)canReplayForContainer:(NSString *)container { return [self.scenes objectForKey:container].tapSyncPeer.canReplay; }
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
    _sourceContainer = source.copy;
    NSMutableOrderedSet *unique = [NSMutableOrderedSet orderedSetWithArray:targets];
    if (source) [unique removeObject:source];
    _targetContainers = unique.array;
    _statusKey = source && unique.count ? @"lc.tapSync.paused" : @"lc.tapSync.chooseWindows";
    [self changed];
}
- (NSDictionary *)selectionPropertyList {
    if (!self.sourceContainer || self.targetContainers.count == 0) return @{};
    return @{@"source": self.sourceContainer, @"targets": self.targetContainers};
}
- (void)restoreSelection:(NSDictionary *)selection {
    NSString *source = [selection[@"source"] isKindOfClass:NSString.class] ? selection[@"source"] : nil;
    NSArray *targets = [selection[@"targets"] isKindOfClass:NSArray.class] ? selection[@"targets"] : @[];
    [self selectSource:source targets:targets];
    if (source && targets.count) {
        _statusKey = @"lc.tapSync.restoredPaused";
        [self changed];
    }
}
- (NSArray *)currentGeometry {
    if (!self.host.window || !self.sourceContainer || self.targetContainers.count == 0 ||
        self.host.isAdjustingGridDividers || self.host.isChoosingGridSwap) return nil;
    NSArray *participants = [@[self.sourceContainer] arrayByAddingObjectsFromArray:self.targetContainers];
    NSMutableArray *geometry = [NSMutableArray arrayWithObjects:[NSValue valueWithCGRect:self.host.bounds],
        [NSValue valueWithUIEdgeInsets:self.host.safeAreaInsets], @(self.host.window.windowScene.interfaceOrientation), nil];
    NSArray<DecoratedAppSceneViewController *> *visible = self.host.tapSyncWindows;
    NSString *bundle;
    CGSize sourceSize = CGSizeZero;
    for (NSString *container in participants) {
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
    return geometry.copy;
}
- (BOOL)canStart { return !self.active && !self.starting && [self currentGeometry] != nil; }
- (void)start {
    if (self.active || self.starting) return;
    NSArray *geometry = [self currentGeometry];
    if (!geometry) { _statusKey = @"lc.tapSync.alignWindows"; [self changed]; return; }
    LCTapSyncSession *session = [[LCTapSyncSession alloc] initWithSource:self.sourceContainer targets:self.targetContainers];
    if (!session) return;
    self.session = session;
    self.geometry = geometry;
    self.inFlightSequence = 0;
    _forwardedTapCount = 0;
    _starting = YES;
    _statusKey = @"lc.tapSync.starting";
    [self changed];
    __block NSUInteger remaining = session.targets.count;
    for (NSString *container in session.targets) {
        [[self.scenes objectForKey:container].tapSyncPeer prepareSession:session.identifier source:NO reply:^(LCTapSyncResult result) {
            if (self.session != session) return;
            if (result != LCTapSyncResultAccepted) { [self stopWithResult:result]; return; }
            if (--remaining != 0) return;
            [[self.scenes objectForKey:session.source].tapSyncPeer prepareSession:session.identifier source:YES reply:^(LCTapSyncResult sourceResult) {
                if (self.session != session) return;
                if (sourceResult != LCTapSyncResultAccepted) { [self stopWithResult:sourceResult]; return; }
                [self validateWindows];
                if (self.session != session) return;
                self->_starting = NO;
                self->_active = YES;
                self->_statusKey = @"lc.tapSync.active";
                [self changed];
                [self sendNext];
            }];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.session == session && self.starting) [self stopWithStatus:@"lc.tapSync.unavailable"];
    });
}
- (void)receiveTap:(NSDictionary *)tap source:(NSString *)source session:(NSString *)identifier sequence:(uint64_t)sequence {
    LCTapSyncSession *session = self.session;
    if (!session || ![session.identifier isEqualToString:identifier] || ![session.source isEqualToString:source]) return;
    [self validateWindows];
    if (self.session != session) return;
    LCTapSyncResult result = [session enqueue:tap fromSource:source session:identifier sequence:sequence
        now:NSProcessInfo.processInfo.systemUptime];
    if (result != LCTapSyncResultAccepted) { [self stopWithResult:result]; return; }
    [self sendNext];
}
- (void)sendNext {
    LCTapSyncSession *session = self.session;
    if (!self.active || !session || self.inFlightSequence) return;
    [self validateWindows];
    if (self.session != session) return;
    LCTapSyncResult result;
    NSDictionary *next = [session takeNextAtTime:NSProcessInfo.processInfo.systemUptime result:&result];
    if (result != LCTapSyncResultAccepted) { [self stopWithResult:result]; return; }
    if (!next) return;
    uint64_t sequence = [next[@"sequence"] unsignedLongLongValue];
    self.inFlightSequence = sequence;
    __block NSUInteger remaining = session.targets.count;
    for (NSString *container in session.targets) {
        [[self.scenes objectForKey:container].tapSyncPeer replayTap:next[@"tap"] session:session.identifier sequence:sequence reply:^(LCTapSyncResult reply) {
            if (self.session != session || self.inFlightSequence != sequence) return;
            if (reply != LCTapSyncResultAccepted) { [self stopWithResult:reply]; return; }
            if (--remaining != 0) return;
            self.inFlightSequence = 0;
            self->_forwardedTapCount += 1;
            [self changed];
            [self sendNext];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.session == session && self.inFlightSequence == sequence) [self stopWithStatus:@"lc.tapSync.tooSlow"];
    });
}
- (void)stopWithResult:(LCTapSyncResult)result {
    NSString *status = @"lc.tapSync.unavailable";
    switch (result) {
        case LCTapSyncResultUnsupported: status = @"lc.tapSync.unsupported"; break;
        case LCTapSyncResultGeometryChanged: status = @"lc.tapSync.layoutChanged"; break;
        case LCTapSyncResultBusy: status = @"lc.tapSync.interrupted"; break;
        case LCTapSyncResultExpired: status = @"lc.tapSync.tooSlow"; break;
        case LCTapSyncResultStopped: status = @"lc.tapSync.paused"; break;
        default: break;
    }
    [self stopWithStatus:status];
}
- (void)stopWithStatus:(NSString *)status {
    LCTapSyncSession *session = self.session;
    self.session = nil;
    [session invalidate];
    self.geometry = nil;
    self.inFlightSequence = 0;
    _active = NO;
    _starting = NO;
    _statusKey = status;
    if (session) {
        for (NSString *container in [@[session.source] arrayByAddingObjectsFromArray:session.targets]) {
            [[self.scenes objectForKey:container].tapSyncPeer stopSession:session.identifier];
        }
    }
    [self changed];
}
- (void)pause { [self stopWithStatus:@"lc.tapSync.paused"]; }
- (void)pauseForWindowChange {
    if (self.session) [self stopWithStatus:@"lc.tapSync.layoutChanged"];
}
- (void)validateWindows {
    if (self.session && ![self.geometry isEqual:[self currentGeometry]]) [self pauseForWindowChange];
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
    if (self.session) [self stopWithStatus:@"lc.tapSync.backgroundPaused"];
}
@end
