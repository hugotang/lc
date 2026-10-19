#import "PiPManager.h"
#import "DecoratedAppSceneViewController.h"
#import "../LiveContainer/LCSharedUtils.h"
#import "../LiveContainer/utils.h"

static void *LCPiPBoundsContext = &LCPiPBoundsContext;

API_AVAILABLE(ios(16.0))
@interface PiPManager ()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic, strong) AppSceneViewController *displayingVC;
@property(nonatomic, strong) AppSceneViewController *pendingVC;
@property(nonatomic) BOOL starting, startSubmitted, stopping, stopRequested, contentMoved, observingBounds;
@end

@implementation PiPManager
+ (instancetype)shared {
    static PiPManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
    return self;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    id delegate = self.displayingVC.delegate;
    return [delegate isKindOfClass:DecoratedAppSceneViewController.class] ? delegate : nil;
}

- (BOOL)isPiP { return self.pipController.isPictureInPictureActive; }
- (BOOL)isPiPWithVC:(AppSceneViewController *)vc {
    return (self.isPiP || self.starting) && self.displayingVC == vc;
}
- (BOOL)isPiPWithDecoratedVC:(UIViewController *)vc {
    return (self.isPiP || self.starting) && self.displayingDecoratedVC == vc;
}

- (void)startPiPWithVC:(AppSceneViewController *)vc {
    if (!vc.isAppRunning || [self isPiPWithVC:vc]) return;
    self.pendingVC = vc;
    if (self.isPiP || self.starting || self.stopping) [self stopCurrentPiP];
    else [self startPendingPiP];
}

- (void)startPendingPiP {
    if (!self.pendingVC || self.starting || self.stopping || self.isPiP) return;
    AppSceneViewController *vc = self.pendingVC;
    self.pendingVC = nil;
    [self releaseCurrentSession];
    if (!vc.isAppRunning || !vc.view.window) return;
    self.displayingVC = vc;
    self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];
    self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
    if (vc.usesHostingControllerAPI) {
        self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
        self.pipVideoCallContentView.layer.anchorPoint = CGPointZero;
        self.pipVideoCallContentView.layer.position = CGPointZero;
    } else {
        self.pipVideoCallContentView = vc.contentView;
    }
    AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc]
        initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
    AVPictureInPictureController *controller = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.pipController = controller;
    controller.canStartPictureInPictureAutomaticallyFromInline = YES;
    controller.delegate = self;
    [controller setValue:@1 forKey:@"controlsStyle"];
    self.starting = YES;
    // The keyboard belongs to the guest process; resigning the host's first responder is insufficient.
    [LCSharedUtils requestKeyboardDismissalForContainer:vc.dataUUID];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.pipController != controller || !self.starting) return;
        if (!vc.isAppRunning) {
            [self releaseCurrentSession];
            [self startPendingPiP];
            return;
        }
        self.startSubmitted = YES;
        [controller startPictureInPicture];
    });
}

- (void)stopPiP {
    self.pendingVC = nil;
    [self stopCurrentPiP];
}

- (void)stopPiPForVC:(AppSceneViewController *)vc {
    if (self.pendingVC == vc) self.pendingVC = nil;
    if (self.displayingVC == vc) [self stopCurrentPiP];
}

- (void)stopCurrentPiP {
    self.stopRequested = YES;
    if (self.stopping) return;
    if (self.isPiP) {
        self.stopping = YES;
        [self.pipController stopPictureInPicture];
    } else if (!self.starting || !self.startSubmitted) {
        [self releaseCurrentSession];
        [self startPendingPiP];
    }
    // If AVKit is starting, wait for didStart/failedToStart before switching the content source.
}

- (void)restoreContent {
    if (self.observingBounds) {
        [self.pipVideoCallViewController.view.layer removeObserver:self forKeyPath:@"bounds" context:LCPiPBoundsContext];
        self.observingBounds = NO;
    }
    if (!self.contentMoved) return;
    self.contentMoved = NO;
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    AppSceneViewController *vc = self.displayingVC;
    vc.shouldIgnoreSceneUpdates = NO;
    if (vc.contentView) [vc.view insertSubview:vc.contentView atIndex:0];
    [vc setBackgroundNotificationEnabled:true];
    if (vc.isAppRunning) [self.displayingDecoratedVC unminimizeWindowPiP];
    [self.displayingDecoratedVC updateVerticalConstraints];
    [vc.view setNeedsLayout];
}

- (void)releaseCurrentSession {
    [self restoreContent];
    self.pipController.delegate = nil;
    self.pipController = nil;
    self.pipVideoCallViewController = nil;
    self.pipVideoCallContentView = nil;
    self.displayingVC = nil;
    self.starting = self.startSubmitted = self.stopping = self.stopRequested = NO;
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller {
    if (controller != self.pipController || self.contentMoved) return;
    self.starting = self.startSubmitted = YES;
    AppSceneViewController *vc = self.displayingVC;
    [LCSharedUtils requestKeyboardDismissalForContainer:vc.dataUUID];
    [self.displayingDecoratedVC minimizeWindowPiP];
    self.contentMoved = YES;
    if (vc.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = (CGRect){CGPointZero, vc.view.bounds.size};
        self.pipVideoCallViewController.additionalSafeAreaInsets = vc.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:vc.contentView];
    } else {
        vc.contentView.frame = (CGRect){CGPointZero, vc.view.bounds.size};
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    [self.pipVideoCallViewController.view.layer addObserver:self forKeyPath:@"bounds"
                                                  options:NSKeyValueObservingOptionNew context:LCPiPBoundsContext];
    self.observingBounds = YES;
    self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
    [vc setBackgroundNotificationEnabled:false];
    vc.shouldIgnoreSceneUpdates = YES;
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    if (controller != self.pipController) return;
    self.starting = NO;
    if (self.stopRequested || self.pendingVC || !self.displayingVC.isAppRunning) [self stopCurrentPiP];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)controller {
    if (controller != self.pipController) return;
    self.stopping = YES;
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    if (controller != self.pipController) return;
    [self restoreContent];
    self.starting = self.startSubmitted = self.stopping = self.stopRequested = NO;
    if (self.pendingVC || !self.displayingVC.isAppRunning || [NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        [self releaseCurrentSession];
    }
    [self startPendingPiP];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    if (controller != self.pipController) return;
    NSLog(@"PiP failed to start: %@", error);
    [self releaseCurrentSession];
    [self startPendingPiP];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(NSObject *)object change:(NSDictionary<NSString *, id> *)change context:(void *)context {
    if (context != LCPiPBoundsContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (object != self.pipVideoCallViewController.view.layer || !self.contentMoved) return;
    CGRect rect = [change[NSKeyValueChangeNewKey] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGSize size = self.displayingVC.contentView.bounds.size;
    if (size.width <= 0 || size.height <= 0 || scale <= 0) return;
    self.pipVideoCallContentView.transform = CGAffineTransformMakeScale(rect.size.width / size.width / scale,
                                                                      rect.size.height / size.height / scale);
}
@end
