//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "TapSyncCoordinator.h"
#import "WindowContentGeometry.h"

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@property(nonatomic) BOOL didCompleteInitialization;
@property(nonatomic, copy) dispatch_block_t launchRequest;
@end

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    return [self initWithBundleId:bundleId dataUUID:dataUUID delegate:delegate deferLaunch:NO];
}

- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate deferLaunch:(BOOL)deferLaunch {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error || !_extension) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeInitializationWithError:error ?: [self startupError]];
            [self appTerminationCleanUp];
        });
        return self;
    }
    _extension.preferredLanguages = @[];
    if (!self.isNativeWindow) {
        self.tapSyncPeer = [LCTapSyncPeer new];
        [LCTapSyncCoordinator.shared registerScene:self];
    }
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    userInfo[@"virtualWindow"] = @(!self.isNativeWindow);
    if (self.tapSyncPeer) userInfo[@"tapSyncEndpoint"] = self.tapSyncPeer.endpoint;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        [bookmarks addObject:bookmarkData];
    } else {
        bool isSharedApp = false;
        NSBundle* bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
        // when mutlitask with private app, we can restrict its sandbox to only its own container
        if (!isSharedApp) {
            NSURL *dataURL = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
            NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
            [bookmarks addObject:[bundle.bundleURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
            NSData* containerBookmark = [dataURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(containerBookmark) {
                [bookmarks addObject:containerBookmark];
            }
            [bookmarks addObject:[tweaksURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *vc = weakSelf;
            [vc completeInitializationWithError:error ?: [vc startupError]];
            [vc appTerminationCleanUp];
        });
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appTerminationCleanUp];
        });
    }];
    void (^beginRequest)(void) = ^{
        AppSceneViewController *controller = weakSelf;
        if (!controller || controller.didCompleteInitialization || controller.isAppTerminationCleanUpCalled) return;
        [controller.extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (controller.didCompleteInitialization || controller.isAppTerminationCleanUpCalled) return;
                controller.pid = identifier ? [controller.extension pidForRequestIdentifier:identifier] : 0;
                if (identifier && controller.pid > 0) {
                    controller.tapSyncPeer.expectedProcessIdentifier = controller.pid;
                    [MultitaskManager registerMultitaskContainerWithContainer:controller.dataUUID];
                    controller.identifier = identifier;
                    [controller completeInitializationWithError:nil];
                    [controller setUpAppPresenter];
                } else {
                    [controller completeInitializationWithError:[controller startupError]];
                    [controller appTerminationCleanUp];
                }
            });
        }];
    };
    bool guestIsShared = false;
    NSBundle *guestBundle = !self.isNativeWindow ? [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&guestIsShared] : nil;
    NSDictionary *guestInfo = guestBundle ? [NSDictionary dictionaryWithContentsOfFile:[guestBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]] : nil;
    BOOL reportWindowGeometry = [guestInfo[@"LCUseWindowScreenSize"] boolValue] && ![guestInfo[@"dontInjectTweakLoader"] boolValue];
    self.launchRequest = ^{
        AppSceneViewController *controller = weakSelf;
        if (!controller || controller.didCompleteInitialization || controller.isAppTerminationCleanUpCalled) return;
        if (reportWindowGeometry) {
            // The current orientation's laid-out content is also used for the
            // first scene and later rotation. Divide the saved scale once.
            CGSize size = LCWindowContentLogicalSize(controller.view.bounds.size, controller.scaleRatio);
            if (size.width >= 1 && size.height >= 1) {
                userInfo[@"initialWindowWidth"] = @(size.width);
                userInfo[@"initialWindowHeight"] = @(size.height);
                item.userInfo = userInfo;
            }
        }
        beginRequest();
    };
    if (!deferLaunch) {
        if (reportWindowGeometry) dispatch_async(dispatch_get_main_queue(), ^{ [self startApp]; });
        else [self startApp];
    }
    
    return self;
}

- (void)startApp {
    NSAssert(NSThread.isMainThread, @"Guest launch geometry is prepared on the main thread");
    dispatch_block_t request = self.launchRequest;
    self.launchRequest = nil;
    if (request) request();
}

- (NSError *)startupError {
    NSString *message = [NSString stringWithFormat:@"%@\n%@", @"lc.multitask.startFailed".loc,
                         NSProcessInfo.processInfo.operatingSystemVersionString];
    return [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Extension completion, cancellation and interruption can all arrive for the same request.
// Deliver exactly once on the main queue, including failures, to resume Swift continuations safely.
- (void)completeInitializationWithError:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"Launch completion must run on the main thread");
    if (self.didCompleteInitialization) return;
    self.didCompleteInitialization = YES;
    [self.delegate appSceneVC:self didInitializeWithError:error];
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        if (!self.isNativeWindow) {
            // Initial parameters are delivered before later hosting-view
            // updates. Supply the laid-out logical size here as well, including
            // at 100% scale, rather than starting with the physical display.
            settings.frame = LCWindowContentSceneFrame((CGRect){CGPointZero, self.view.bounds.size},
                self.scaleRatio, NO, settings.interfaceOrientation);
        }
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        if (!self.isNativeWindow) {
            // Prepare both logical bounds and saved scale before any initial
            // scene configuration can deliver geometry to the guest.
            LCWindowContentApplyHostingSize(self.contentView, self.view.bounds.size, self.scaleRatio);
        }
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        if (!self.isNativeWindow) {
            self.shouldSkipDebounceOnce = YES;
            [self updateFrameWithSettingsBlock:nil];
        }
        [self addChildViewController:self.hostingController.sceneViewController];
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
        self.contentView.layer.sublayerTransform = CATransform3DMakeScale(self.scaleRatio, self.scaleRatio, 1);
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    // Before the private scene exists, this is only Auto Layout preparation.
    // Applying a saved scale here would divide the host guest view itself and
    // then divide it again when serializing the launch dimensions.
    if (!self.presenter || self.isAppTerminationCleanUpCalled) return;
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            frame.size = self.view.bounds.size;
            settings.frame = LCWindowContentSceneFrame(frame, self.scaleRatio,
                self.usesHostingControllerAPI, settings.interfaceOrientation);
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18.0 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        if (self.hostingController && !self.isNativeWindow) {
            LCWindowContentApplyHostingSize(self.contentView, frame.size, self.scaleRatio);
        } else {
            frame.origin = CGPointZero;
            self.contentView.frame = frame;
        }
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appTerminationCleanUp]; });
        return;
    }
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    self.launchRequest = nil;
    [LCTapSyncCoordinator.shared unregisterScene:self];
    if (!self.didCompleteInitialization) [self completeInitializationWithError:[self startupError]];
    [PiPManager.shared stopPiPForVC:self];
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 
