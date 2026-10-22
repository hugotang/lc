#import "TapSyncControlsView.h"
#import "TapSyncCoordinator.h"
#import "PerformanceMonitor.h"
#import "../LiveContainer/Localization.h"
#import "../LiveContainer/utils.h"

@interface LCTapSyncControlsView ()
@property(nonatomic) UIVisualEffectView *background;
@property(nonatomic) UIButton *toggleButton, *settingsButton;
@property(nonatomic) UIPanGestureRecognizer *pan;
@property(nonatomic) CGRect placementBounds, availableBounds;
@property(nonatomic) UIEdgeInsets placementInsets;
@property(nonatomic) CGPoint dragStartCenter;
@property(nonatomic) BOOL dragging, landscape, dragLandscape;
@end

@implementation LCTapSyncControlsView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 22;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.16;
        self.layer.shadowRadius = 5;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        _background = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        _background.userInteractionEnabled = NO;
        _background.layer.cornerRadius = 22;
        _background.clipsToBounds = YES;
        [self addSubview:_background];
        _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_toggleButton addTarget:self action:@selector(toggleSync) forControlEvents:UIControlEventTouchUpInside];
        _toggleButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_toggleButton];
        _settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_settingsButton];
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveControls:)];
        _pan.maximumNumberOfTouches = 1;
        _pan.cancelsTouchesInView = YES;
        [self addGestureRecognizer:_pan];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:)
                                                   name:UIContentSizeCategoryDidChangeNotification object:nil];
        [self refresh];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)contentSizeChanged:(NSNotification *)note { [self refresh]; }
- (void)toggleSync {
    if (self.showsPerformance) { if (self.configure) self.configure(); return; }
    LCTapSyncCoordinator *sync = LCTapSyncCoordinator.shared;
    if (sync.active || sync.starting) [sync pause];
    else [sync start];
}
- (void)openSettings {
    if (self.showsPerformance) LCPerformanceMonitor.shared.enabled = NO;
    else if (self.configure) self.configure();
}
- (NSString *)positionKey {
    if (self.showsPerformance) return self.landscape ? @"LCPerformanceControlsLandscapePosition" : @"LCPerformanceControlsPortraitPosition";
    return self.landscape ? @"LCTapSyncControlsLandscapePosition" : @"LCTapSyncControlsPortraitPosition";
}
- (void)setShowsPerformance:(BOOL)showsPerformance { _showsPerformance = showsPerformance; [self refresh]; }
- (void)refresh {
    if (self.showsPerformance) { [self refreshPerformance]; [self refreshPlacementActions]; return; }
    LCTapSyncCoordinator *sync = LCTapSyncCoordinator.shared;
    BOOL compact = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCTapSyncCompactControls"];
    BOOL running = sync.active || sync.starting;
    NSString *title = [NSString localizedStringWithFormat:(running ? @"lc.tapSync.overlayActive" : @"lc.tapSync.overlayResume").loc,
        (long)sync.targetContainers.count];
    UIButtonConfiguration *configuration = UIButtonConfiguration.tintedButtonConfiguration;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.baseBackgroundColor = running ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.image = [UIImage systemImageNamed:running ? @"pause.fill" : @"play.fill"];
    configuration.imagePadding = 7;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
    configuration.title = compact ? [NSString stringWithFormat:@"1 → %lu", (unsigned long)sync.targetContainers.count] :
        sync.starting ? @"lc.tapSync.starting".loc : title;
    NSMutableArray *affected = [NSMutableArray array];
    for (NSString *container in sync.interruptedContainers) {
        [affected addObject:[NSString stringWithFormat:@"#%lu", (unsigned long)[sync windowNumberForContainer:container]]];
    }
    NSString *status = affected.count ? [NSString stringWithFormat:@"%@ · %@", [affected componentsJoinedByString:@", "], sync.statusKey.loc] : sync.statusKey.loc;
    configuration.subtitle = !compact && !running ? status : nil;
    configuration.titleLineBreakMode = NSLineBreakByTruncatingTail;
    configuration.subtitleLineBreakMode = NSLineBreakByTruncatingTail;
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        return result;
    };
    configuration.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        return result;
    };
    self.toggleButton.configuration = configuration;
    self.toggleButton.accessibilityLabel = (running ? @"lc.tapSync.pause" : @"lc.tapSync.resume").loc;
    self.toggleButton.accessibilityValue = [NSString stringWithFormat:@"%@. %@", title, status];
    self.toggleButton.accessibilityHint = @"lc.tapSync.dragControls".loc;
    UIButtonConfiguration *settings = UIButtonConfiguration.plainButtonConfiguration;
    settings.image = [UIImage systemImageNamed:@"gearshape" withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium]];
    settings.baseForegroundColor = UIColor.labelColor;
    self.settingsButton.configuration = settings;
    self.settingsButton.accessibilityLabel = @"lc.tapSync.configure".loc;
    [self refreshPlacementActions];
}
- (void)refreshPlacementActions {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    NSArray<NSString *> *keys = @[@"lc.tapSync.moveTopLeft", @"lc.tapSync.moveTopRight", @"lc.tapSync.moveBottomLeft", @"lc.tapSync.moveBottomRight"];
    for (NSUInteger index = 0; index < keys.count; index++) {
        BOOL right = index % 2 != 0;
        CGFloat fraction = index >= 2 ? 1 : 0;
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:keys[index].loc actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
            [weakSelf dockRight:right fraction:fraction];
            return YES;
        }]];
    }
    self.toggleButton.accessibilityCustomActions = actions;
    if (self.superview) [self placeInBounds:self.placementBounds safeAreaInsets:self.placementInsets];
}
- (void)refreshPerformance {
    LCPerformanceMonitor *monitor = LCPerformanceMonitor.shared;
    NSDictionary *sample = monitor.snapshot, *sync = sample[@"sync"];
    NSString *(^number)(id) = ^NSString *(id value) { return value ? [NSString localizedStringWithFormat:@"%.0f", [value doubleValue]] : @"—"; };
    UIButtonConfiguration *configuration = UIButtonConfiguration.plainButtonConfiguration;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 4);
    configuration.title = [NSString localizedStringWithFormat:@"lc.performance.overlayTotals".loc,
        number(sample[@"totalCPU"]), number(sample[@"totalMemoryMiB"])];
    NSArray *thermalKeys = @[@"lc.performance.thermal.nominal", @"lc.performance.thermal.fair", @"lc.performance.thermal.serious", @"lc.performance.thermal.critical"];
    NSInteger thermal = [sample[@"thermalState"] integerValue];
    NSString *state = sample[@"thermalState"] && thermal >= 0 && thermal < (NSInteger)thermalKeys.count ? thermalKeys[thermal].loc : @"lc.performance.waiting".loc;
    configuration.subtitle = monitor.sampling ? [NSString localizedStringWithFormat:@"lc.performance.overlayResponse".loc,
        number(sync[@"responseP95Ms"]), state] : @"lc.performance.suspended".loc;
    configuration.titleLineBreakMode = NSLineBreakByTruncatingTail;
    configuration.subtitleLineBreakMode = NSLineBreakByTruncatingTail;
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        return result;
    };
    configuration.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        return result;
    };
    self.toggleButton.configuration = configuration;
    self.toggleButton.accessibilityLabel = @"lc.performance.title".loc;
    self.toggleButton.accessibilityValue = [NSString stringWithFormat:@"%@. %@", configuration.title, configuration.subtitle];
    self.toggleButton.accessibilityHint = @"lc.tapSync.dragControls".loc;
    UIButtonConfiguration *close = UIButtonConfiguration.plainButtonConfiguration;
    close.image = [UIImage systemImageNamed:@"xmark.circle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]];
    close.baseForegroundColor = UIColor.secondaryLabelColor;
    self.settingsButton.configuration = close;
    self.settingsButton.accessibilityLabel = @"lc.performance.stop".loc;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.background.frame = self.bounds;
    CGFloat settingsWidth = 44;
    self.toggleButton.frame = CGRectMake(0, 0, MAX(0, self.bounds.size.width - settingsWidth), self.bounds.size.height);
    self.settingsButton.frame = CGRectMake(CGRectGetMaxX(self.toggleButton.frame), 0, settingsWidth, self.bounds.size.height);
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:22].CGPath;
}
- (void)placeInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets {
    if (CGRectIsEmpty(bounds)) return;
    self.placementBounds = bounds;
    self.placementInsets = insets;
    self.availableBounds = CGRectInset(UIEdgeInsetsInsetRect(bounds, insets), 8, 8);
    UIInterfaceOrientation orientation = self.window.windowScene.interfaceOrientation;
    self.landscape = orientation == UIInterfaceOrientationUnknown ? bounds.size.width > bounds.size.height : UIInterfaceOrientationIsLandscape(orientation);
    if (self.dragging && self.landscape != self.dragLandscape) {
        self.dragging = NO;
        self.pan.enabled = NO;
        self.pan.enabled = YES;
    }
    CGFloat width = MIN(320, MAX(88, self.availableBounds.size.width));
    CGSize buttonSize = [self.toggleButton sizeThatFits:CGSizeMake(width - 44, CGFLOAT_MAX)];
    CGSize size = CGSizeMake(MIN(width, MAX(88, buttonSize.width + 44)), MAX(44, buttonSize.height));
    if (self.dragging && self.landscape == self.dragLandscape) {
        self.bounds = (CGRect){CGPointZero, size};
        [self clampPosition];
        return;
    }
    NSDictionary *saved = [NSUserDefaults.lcSharedDefaults dictionaryForKey:self.positionKey];
    BOOL right = saved[@"edge"] ? ![saved[@"edge"] isEqual:@"left"] : !self.showsPerformance;
    double fraction = [saved[@"fraction"] isKindOfClass:NSNumber.class] ? [saved[@"fraction"] doubleValue] : self.showsPerformance ? 1 : 0;
    if (!isfinite(fraction)) fraction = 0;
    CGFloat x = right ? CGRectGetMaxX(self.availableBounds) - size.width : CGRectGetMinX(self.availableBounds);
    CGFloat y = CGRectGetMinY(self.availableBounds) + MAX(0, self.availableBounds.size.height - size.height) * MAX(0, MIN(1, fraction));
    self.frame = (CGRect){CGPointMake(x, y), size};
}
- (void)clampPosition {
    CGRect frame = self.frame;
    frame.origin.x = MAX(CGRectGetMinX(self.availableBounds), MIN(frame.origin.x, CGRectGetMaxX(self.availableBounds) - frame.size.width));
    frame.origin.y = MAX(CGRectGetMinY(self.availableBounds), MIN(frame.origin.y, CGRectGetMaxY(self.availableBounds) - frame.size.height));
    self.frame = frame;
}
- (void)dockRight:(BOOL)right fraction:(CGFloat)fraction {
    [NSUserDefaults.lcSharedDefaults setObject:@{@"edge": right ? @"right" : @"left", @"fraction": @(MAX(0, MIN(1, fraction)))}
                                       forKey:self.positionKey];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.2 animations:^{
        [self placeInBounds:self.placementBounds safeAreaInsets:self.placementInsets];
        [self layoutIfNeeded];
    }];
}
- (void)moveControls:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.dragLandscape = self.landscape;
        self.dragStartCenter = self.center;
    }
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        if (self.dragLandscape != self.landscape) return;
        CGPoint translation = [gesture translationInView:self.superview];
        self.center = CGPointMake(self.dragStartCenter.x + translation.x, self.dragStartCenter.y + translation.y);
        [self clampPosition];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        self.dragging = NO;
        if (self.dragLandscape == self.landscape) {
            CGPoint translation = [gesture translationInView:self.superview];
            self.center = CGPointMake(self.dragStartCenter.x + translation.x, self.dragStartCenter.y + translation.y);
            [self clampPosition];
            CGFloat height = self.availableBounds.size.height - self.bounds.size.height;
            CGFloat fraction = height > 0 ? (self.frame.origin.y - self.availableBounds.origin.y) / height : 0;
            [self dockRight:self.center.x >= CGRectGetMidX(self.availableBounds) fraction:fraction];
        } else [self placeInBounds:self.placementBounds safeAreaInsets:self.placementInsets];
    } else if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        [self placeInBounds:self.placementBounds safeAreaInsets:self.placementInsets];
    }
}
@end
