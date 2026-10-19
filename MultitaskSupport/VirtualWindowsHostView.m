//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "WindowGridLayout.h"
#import "WindowGridOrder.h"
#import "WindowKeyboardGeometry.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainer/Localization.h"
#import "../LiveContainer/utils.h"
#import <QuartzCore/QuartzCore.h>

static LCWindowGridRect LCKeyboardRect(CGRect rect) {
    return (LCWindowGridRect){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}
static CGRect LCCGKeyboardRect(LCWindowGridRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}

@interface LCKeyboardWindowFrame : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect hostBounds;
@end
@implementation LCKeyboardWindowFrame
@end

@interface LCGridProportions : NSObject
@property(nonatomic, strong) NSMutableData *rows;
@property(nonatomic, strong) NSMutableData *columns;
@property(nonatomic, strong) NSMutableData *lastRowColumns;
- (instancetype)initWithLayout:(LCWindowGridLayout)layout;
- (instancetype)initWithPropertyList:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)values;
- (NSDictionary *)propertyList;
@end

@implementation LCGridProportions
- (instancetype)initWithLayout:(LCWindowGridLayout)layout {
    self = [super init];
    if (self) {
        size_t lastRowCount = layout.count - (layout.rows - 1) * layout.columns;
        _rows = [NSMutableData dataWithLength:(layout.rows - 1) * sizeof(double)];
        _columns = [NSMutableData dataWithLength:(layout.columns - 1) * sizeof(double)];
        _lastRowColumns = [NSMutableData dataWithLength:(lastRowCount - 1) * sizeof(double)];
        LCWindowGridResetDividers(_rows.mutableBytes, layout.rows);
        LCWindowGridResetDividers(_columns.mutableBytes, layout.columns);
        LCWindowGridResetDividers(_lastRowColumns.mutableBytes, lastRowCount);
    }
    return self;
}
- (instancetype)initWithPropertyList:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)values {
    self = [super init];
    if (self) {
        NSMutableArray *buffers = [NSMutableArray array];
        for (NSString *key in @[@"rows", @"columns", @"lastRowColumns"]) {
            NSArray<NSNumber *> *numbers = values[key];
            NSMutableData *data = [NSMutableData dataWithLength:numbers.count * sizeof(double)];
            double *fractions = data.mutableBytes;
            for (NSUInteger i = 0; i < numbers.count; ++i) fractions[i] = numbers[i].doubleValue;
            [buffers addObject:data];
        }
        _rows = buffers[0];
        _columns = buffers[1];
        _lastRowColumns = buffers[2];
    }
    return self;
}
- (NSDictionary *)propertyList {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"rows", @"columns", @"lastRowColumns"];
    NSArray<NSData *> *buffers = @[self.rows, self.columns, self.lastRowColumns];
    for (NSUInteger i = 0; i < keys.count; ++i) {
        const double *fractions = buffers[i].bytes;
        NSMutableArray *numbers = [NSMutableArray array];
        for (NSUInteger j = 0; j < buffers[i].length / sizeof(double); ++j) [numbers addObject:@(fractions[j])];
        result[keys[i]] = numbers.copy;
    }
    return result.copy;
}
@end

// Only the controls intercept touches; uncovered space still reaches the app windows.
@interface LCGridControlsOverlay : UIView
@property(nonatomic, copy) void (^escapeHandler)(void);
@end

@implementation LCGridControlsOverlay
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
- (BOOL)accessibilityPerformEscape {
    if (!self.escapeHandler) return NO;
    self.escapeHandler();
    return YES;
}
@end

@interface LCGridDividerView : UIView
@property(nonatomic) NSInteger rowDivider;
@property(nonatomic) NSInteger columnDivider;
@property(nonatomic) BOOL dividesLastRow;
@property(nonatomic) CGPoint gripPosition;
@property(nonatomic, strong) UIView *line;
@property(nonatomic, strong) UIView *grip;
@property(nonatomic, strong) UIImageView *symbol;
@property(nonatomic, copy) void (^accessibilityAdjustment)(NSInteger direction);
- (instancetype)initWithRow:(NSInteger)row column:(NSInteger)column lastRow:(BOOL)lastRow;
@end

@implementation LCGridDividerView
- (instancetype)initWithRow:(NSInteger)row column:(NSInteger)column lastRow:(BOOL)lastRow {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _rowDivider = row;
        _columnDivider = column;
        _dividesLastRow = lastRow;
        self.exclusiveTouch = YES;
        _line = [UIView new];
        _line.backgroundColor = UIColor.systemBlueColor;
        _line.userInteractionEnabled = NO;
        [self addSubview:_line];
        _grip = [UIView new];
        _grip.backgroundColor = UIColor.systemBlueColor;
        _grip.userInteractionEnabled = NO;
        _grip.layer.borderColor = UIColor.whiteColor.CGColor;
        _grip.layer.borderWidth = 1;
        [self addSubview:_grip];
        BOOL intersection = row >= 0 && column >= 0;
        NSString *symbol = intersection ? @"arrow.up.and.down.and.arrow.left.and.right" :
                           row >= 0 ? @"arrow.up.and.down" : @"arrow.left.and.right";
        _symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]]];
        _symbol.tintColor = UIColor.whiteColor;
        _symbol.contentMode = UIViewContentModeCenter;
        [_grip addSubview:_symbol];
        // Each axis is separately adjustable with VoiceOver; intersections are a touch shortcut.
        self.isAccessibilityElement = !intersection;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        self.accessibilityLabel = (row >= 0 ? @"lc.multitask.rowDivider" : @"lc.multitask.columnDivider").loc;
        self.accessibilityHint = @"lc.multitask.dividerAdjustmentHint".loc;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL intersection = self.rowDivider >= 0 && self.columnDivider >= 0;
    BOOL horizontal = self.rowDivider >= 0;
    self.line.hidden = intersection;
    self.line.frame = horizontal ? CGRectMake(0, CGRectGetMidY(self.bounds) - 1, self.bounds.size.width, 2) :
                                  CGRectMake(CGRectGetMidX(self.bounds) - 1, 0, 2, self.bounds.size.height);
    CGSize gripSize = intersection ? CGSizeMake(30, 30) : horizontal ? CGSizeMake(48, 24) : CGSizeMake(24, 48);
    self.grip.bounds = (CGRect){CGPointZero, gripSize};
    self.grip.center = self.gripPosition;
    self.grip.layer.cornerRadius = intersection ? 15 : 8;
    self.symbol.frame = self.grip.bounds;
}
- (void)accessibilityIncrement {
    if (self.accessibilityAdjustment) self.accessibilityAdjustment(1);
}
- (void)accessibilityDecrement {
    if (self.accessibilityAdjustment) self.accessibilityAdjustment(-1);
}
@end

@interface VirtualWindowsHostView ()
@property(nonatomic, strong) LCWindowGridOrder *windowOrder;
@property(nonatomic) NSArray<UIView *> *lastArrangedWindows;
@property(nonatomic) CGRect lastArrangementBounds;
@property(nonatomic) BOOL wasAutomaticallyTiling;
@property(nonatomic) BOOL wasHidingGridWindowBars;
@property(nonatomic, readwrite) BOOL hasVisibleGridWindows;
@property(nonatomic) BOOL isArrangingWindows;
@property(nonatomic, readwrite) BOOL isAdjustingGridDividers;
@property(nonatomic, readwrite) BOOL isChoosingGridSwap;
@property(nonatomic) LCWindowGridLayout gridLayout;
@property(nonatomic, strong) LCGridProportions *gridProportions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LCGridProportions *> *savedGridProportions;
@property(nonatomic, strong) LCGridControlsOverlay *dividerOverlay;
@property(nonatomic, strong) LCGridControlsOverlay *swapOverlay;
@property(nonatomic, copy) NSArray<UIView *> *swapCandidates;
@property(nonatomic, weak) UIView *selectedSwapWindow;
@property(nonatomic, weak) LCGridDividerView *activeDivider;
@property(nonatomic) CGPoint dragStartDividerPosition;
@property(nonatomic) CFTimeInterval lastInteractiveSceneUpdate;
@property(nonatomic) CGRect keyboardScreenFrame;
@property(nonatomic) BOOL wasAvoidingKeyboard;
@property(nonatomic) BOOL wasKeyboardAvoidanceEnabled;
@property(nonatomic, strong) NSMapTable<UIView *, LCKeyboardWindowFrame *> *keyboardOriginalFrames;
@property(nonatomic, readonly) BOOL keyboardAvoidanceEnabled, isAvoidingKeyboard, allVisibleWindowsAreInGrid;
@property(nonatomic, readonly) CGRect gridAvailableBounds;
@end

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    self.windowOrder = [LCWindowGridOrder new];
    self.savedGridProportions = [NSMutableDictionary dictionary];
    self.lastArrangementBounds = CGRectNull;
    self.wasAutomaticallyTiling = self.automaticallyTilesWindows;
    self.wasHidingGridWindowBars = self.shouldHideGridWindowBars;
    self.keyboardScreenFrame = CGRectNull;
    self.keyboardOriginalFrames = [NSMapTable weakToStrongObjectsMapTable];
    self.wasKeyboardAvoidanceEnabled = self.keyboardAvoidanceEnabled;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsDidChange:)
                                               name:NSUserDefaultsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:)
                                               name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardFrameDidChange:)
                                               name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardFrameDidChange:)
                                               name:UIKeyboardWillHideNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)automaticallyTilesWindows {
    return [NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoTileMultitaskWindows"];
}

- (BOOL)shouldHideGridWindowBars {
    NSNumber *value = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCHideGridWindowBars"];
    return value ? value.boolValue : YES;
}

- (NSArray<UIView *> *)visibleWindows {
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *view in self.windowOrder.windows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (!view.hidden && view.alpha > 0 && [vc isKindOfClass:DecoratedAppSceneViewController.class] &&
            !vc.appSceneVC.shouldIgnoreSceneUpdates) {
            [visible addObject:view];
        }
    }
    return visible;
}

- (BOOL)canAdjustGridDividers {
    return self.window && self.visibleWindows.count > 1 && !self.isAvoidingKeyboard;
}

- (BOOL)keyboardAvoidanceEnabled {
    NSNumber *value = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultitaskAvoidKeyboard"];
    return value ? value.boolValue : YES;
}

- (CGRect)gridAvailableBounds {
    CGRect bounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (!self.keyboardAvoidanceEnabled || !self.window || CGRectIsNull(self.keyboardScreenFrame)) return bounds;
    CGRect keyboard = [self convertRect:self.keyboardScreenFrame fromCoordinateSpace:self.window.screen.coordinateSpace];
    return LCCGKeyboardRect(LCKeyboardAvailableRect(LCKeyboardRect(bounds), LCKeyboardRect(keyboard)));
}

- (BOOL)isAvoidingKeyboard {
    return !CGRectEqualToRect(self.gridAvailableBounds, UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets));
}

- (BOOL)allVisibleWindowsAreInGrid {
    NSArray<UIView *> *visible = self.visibleWindows;
    if (visible.count == 0) return NO;
    for (UIView *view in visible) {
        if (!((DecoratedAppSceneViewController *)view._viewDelegate).isInGridLayout) return NO;
    }
    return YES;
}

- (void)keyboardFrameDidChange:(NSNotification *)notification {
    NSValue *frame = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    self.keyboardScreenFrame = [notification.name isEqualToString:UIKeyboardWillHideNotification] || !frame ? CGRectNull : frame.CGRectValue;
    [self finishGridEditing];
    self.lastArrangementBounds = CGRectNull;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : duration delay:0
                        options:curve | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ [self setNeedsLayout]; [self layoutIfNeeded]; } completion:nil];
}

- (void)forgetKeyboardFrameForWindow:(UIView *)window {
    [self.keyboardOriginalFrames removeObjectForKey:window];
}

- (CGRect)unobscuredFrameForWindow:(UIView *)window {
    LCKeyboardWindowFrame *original = [self.keyboardOriginalFrames objectForKey:window];
    if (!original) return window.frame;
    CGRect normalBounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    return LCCGKeyboardRect(LCKeyboardRestoreWindow(LCKeyboardRect(original.frame), LCKeyboardRect(original.hostBounds), LCKeyboardRect(normalBounds)));
}

- (CGRect)frameByAvoidingKeyboard:(CGRect)frame forWindow:(DecoratedAppSceneViewController *)vc {
    CGRect normalBounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGRect available = self.gridAvailableBounds;
    if (vc.isMaximized) {
        [self forgetKeyboardFrameForWindow:vc.view];
        return self.isAvoidingKeyboard ? LCCGKeyboardRect(LCKeyboardFitWindow(LCKeyboardRect(frame), LCKeyboardRect(available))) : frame;
    }
    LCKeyboardWindowFrame *original = [self.keyboardOriginalFrames objectForKey:vc.view];
    if (original) {
        frame = [self unobscuredFrameForWindow:vc.view];
    }
    if (!self.isAvoidingKeyboard) {
        [self forgetKeyboardFrameForWindow:vc.view];
        return frame;
    }
    if (!original) {
        original = [LCKeyboardWindowFrame new];
        original.frame = frame;
        original.hostBounds = normalBounds;
        [self.keyboardOriginalFrames setObject:original forKey:vc.view];
    }
    return LCCGKeyboardRect(LCKeyboardFitWindow(LCKeyboardRect(frame), LCKeyboardRect(available)));
}

- (BOOL)canUndoGridSwap {
    return self.window && [self.windowOrder canUndoSwapWithVisibleWindows:self.visibleWindows];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self finishGridEditing];
}

- (void)defaultsDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL enabled = self.automaticallyTilesWindows;
        BOOL hideBars = self.shouldHideGridWindowBars;
        BOOL keyboardEnabled = self.keyboardAvoidanceEnabled;
        BOOL stoppedTiling = self.wasAutomaticallyTiling && !enabled;
        if (stoppedTiling) [self finishGridEditing];
        if (enabled != self.wasAutomaticallyTiling || hideBars != self.wasHidingGridWindowBars ||
            keyboardEnabled != self.wasKeyboardAvoidanceEnabled) {
            self.wasKeyboardAvoidanceEnabled = keyboardEnabled;
            self.wasAutomaticallyTiling = enabled;
            self.wasHidingGridWindowBars = hideBars;
            for (UIView *view in self.windowOrder.windows) {
                DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
                if ([vc isKindOfClass:DecoratedAppSceneViewController.class] && vc.isInGridLayout) {
                    if (stoppedTiling) vc.isInGridLayout = NO;
                    [vc updateVerticalConstraints];
                }
            }
            self.lastArrangedWindows = nil;
            self.lastArrangementBounds = CGRectNull;
            [self setNeedsLayout];
        }
    });
}

- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    if ([subview isKindOfClass:LCGridControlsOverlay.class]) return;
    [self cancelGridWindowSwap];
    [self.windowOrder addWindow:subview];
    [self bringGridControlsToFront];
    [self setNeedsLayout];
}

- (void)willRemoveSubview:(UIView *)subview {
    if ([subview isKindOfClass:LCGridControlsOverlay.class]) {
        [super willRemoveSubview:subview];
        return;
    }
    [self cancelGridWindowSwap];
    [self.windowOrder removeWindow:subview];
    [self forgetKeyboardFrameForWindow:subview];
    self.lastArrangedWindows = nil;
    [super willRemoveSubview:subview];
    [self setNeedsLayout];
}

- (void)bringSubviewToFront:(UIView *)view {
    [super bringSubviewToFront:view];
    [self bringGridControlsToFront];
}

- (void)bringGridControlsToFront {
    if (self.dividerOverlay.superview == self) [super bringSubviewToFront:self.dividerOverlay];
    if (self.swapOverlay.superview == self) [super bringSubviewToFront:self.swapOverlay];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self finishGridEditing];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL avoidingKeyboard = self.isAvoidingKeyboard;
    if (self.automaticallyTilesWindows || self.isAdjustingGridDividers || self.isChoosingGridSwap ||
        ((avoidingKeyboard || self.wasAvoidingKeyboard) && self.allVisibleWindowsAreInGrid)) {
        [self arrangeVisibleWindowsInGrid:NO];
    } else if (avoidingKeyboard || self.wasAvoidingKeyboard || self.keyboardOriginalFrames.count > 0) {
        for (UIView *view in self.windowOrder.windows) {
            DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
            if ([vc isKindOfClass:DecoratedAppSceneViewController.class] && !vc.appSceneVC.shouldIgnoreSceneUpdates &&
                CGAffineTransformIsIdentity(view.transform)) {
                [vc updateFrameForKeyboard];
            }
        }
    }
    for (UIView *view in self.visibleWindows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (vc.isAppTerminated && vc.isMaximized) [vc updateFrameForKeyboard];
    }
    self.wasAvoidingKeyboard = avoidingKeyboard;
    [self updateGridBackdrop];
}

- (void)setNeedsGridLayout {
    if (self.automaticallyTilesWindows || self.isAdjustingGridDividers || self.isChoosingGridSwap) {
        self.lastArrangementBounds = CGRectNull;
    }
    [self setNeedsLayout];
}

- (void)arrangeWindowsInGrid {
    [self cancelGridWindowSwap];
    [self arrangeVisibleWindowsInGrid:YES];
}

- (DecoratedAppSceneViewController *)windowForContainer:(NSString *)dataUUID {
    for (UIView *view in self.windowOrder.windows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if ([vc isKindOfClass:DecoratedAppSceneViewController.class] && [vc.appSceneVC.dataUUID isEqualToString:dataUUID]) return vc;
    }
    return nil;
}

- (LCWindowWorkspace *)captureWorkspace {
    [self finishGridEditing];
    NSMutableArray *windows = [NSMutableArray array];
    for (UIView *view in self.visibleWindows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (vc.isAppTerminated || !vc.appSceneVC.isAppRunning) continue;
        LCWorkspaceWindow *entry = [[LCWorkspaceWindow alloc] initWithBundleName:vc.appSceneVC.bundleId
                                                                       dataUUID:vc.appSceneVC.dataUUID scale:vc.scaleRatio];
        if (entry) [windows addObject:entry];
    }
    NSMutableDictionary *proportions = [NSMutableDictionary dictionary];
    for (NSString *key in self.savedGridProportions) proportions[key] = self.savedGridProportions[key].propertyList;
    return [[LCWindowWorkspace alloc] initWithWindows:windows proportions:proportions];
}

- (void)applyWorkspace:(LCWindowWorkspace *)workspace {
    [self finishGridEditing];
    NSMutableArray *ordered = [NSMutableArray array];
    for (LCWorkspaceWindow *entry in workspace.windows) {
        DecoratedAppSceneViewController *vc = [self windowForContainer:entry.dataUUID];
        if (!vc || vc.isAppTerminated || !vc.appSceneVC.isAppRunning || vc.appSceneVC.shouldIgnoreSceneUpdates ||
            ![vc.appSceneVC.bundleId isEqualToString:entry.bundleName]) continue;
        [vc.view.layer removeAllAnimations];
        vc.view.hidden = NO;
        vc.view.alpha = 1;
        vc.view.transform = CGAffineTransformIdentity;
        [vc updateContentScale:entry.scale];
        [ordered addObject:vc.view];
    }
    [self.windowOrder restoreOrderWithWindows:ordered];
    for (NSString *key in workspace.proportions) {
        self.savedGridProportions[key] = [[LCGridProportions alloc] initWithPropertyList:workspace.proportions[key]];
    }
    [self arrangeVisibleWindowsInGrid:YES];
}

- (void)arrangeVisibleWindowsInGrid:(BOOL)force {
    if (self.isArrangingWindows || !self.window) return;

    CGRect normalBounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGRect availableBounds = self.gridAvailableBounds;
    if (availableBounds.size.width <= 0 || availableBounds.size.height <= 44) {
        [self finishGridEditing];
        return;
    }

    NSArray<UIView *> *visibleWindows = self.visibleWindows;
    // A picker is tied to a specific set of windows and screen geometry.
    if (self.isChoosingGridSwap &&
        (!CGRectEqualToRect(availableBounds, self.lastArrangementBounds) || ![visibleWindows isEqualToArray:self.swapCandidates])) {
        [self cancelGridWindowSwap];
    }
    // Reflow only when the visible windows or available space change.
    if (!force && CGRectEqualToRect(availableBounds, self.lastArrangementBounds) &&
        [visibleWindows isEqualToArray:self.lastArrangedWindows]) return;

    self.lastArrangementBounds = availableBounds;
    self.lastArrangedWindows = visibleWindows.copy;
    LCWindowGridLayout layout = LCWindowGridLayoutMake(visibleWindows.count, normalBounds.size.width,
                                                      normalBounds.size.height, LCWindowGridSpacing, LCWindowGridMinimumHeight);
    BOOL portrait = layout.height >= layout.width;
    layout.width = availableBounds.size.width;
    layout.height = availableBounds.size.height;
    self.gridLayout = layout;
    if (layout.count == 0) {
        [self finishGridEditing];
        [self updateGridBackdrop];
        return;
    }
    // Keep each grid shape and orientation's proportions for this host's lifetime.
    NSString *key = [NSString stringWithFormat:@"%zu:%zu:%zu:%d", layout.count, layout.rows, layout.columns,
                                               portrait];
    if (!self.savedGridProportions[key]) self.savedGridProportions[key] = [[LCGridProportions alloc] initWithLayout:layout];
    self.gridProportions = self.savedGridProportions[key];
    if (self.isAvoidingKeyboard) {
        // Constraining the temporary keyboard layout must not overwrite the user's normal proportions.
        self.gridProportions = [[LCGridProportions alloc] initWithPropertyList:self.gridProportions.propertyList];
    }
    [self.keyboardOriginalFrames removeAllObjects];
    LCWindowGridConstrainDividers(self.gridProportions.rows.mutableBytes, layout.rows, layout.height,
                                   layout.spacing, LCWindowGridMinimumHeight);
    LCWindowGridConstrainDividers(self.gridProportions.columns.mutableBytes, layout.columns, layout.width,
                                   layout.spacing, LCWindowGridMinimumWidth);
    size_t lastRowCount = layout.count - (layout.rows - 1) * layout.columns;
    LCWindowGridConstrainDividers(self.gridProportions.lastRowColumns.mutableBytes, lastRowCount, layout.width,
                                   layout.spacing, LCWindowGridMinimumWidth);
    [self applyCurrentGridFramesAnimated:YES updateSceneImmediately:NO];
    if (self.isAdjustingGridDividers) {
        if (visibleWindows.count < 2) [self finishGridDividerAdjustment];
        else [self rebuildDividerHandles];
    }
    [self updateGridBackdrop];
    if (self.hasVisibleGridWindows) [MultitaskDockManager.shared collapseDockForGrid];
}

- (void)applyCurrentGridFramesAnimated:(BOOL)animated updateSceneImmediately:(BOOL)immediate {
    LCWindowGridLayout layout = self.gridLayout;
    CGRect bounds = self.lastArrangementBounds;
    self.isArrangingWindows = YES;
    void (^applyFrames)(void) = ^{
        [self.lastArrangedWindows enumerateObjectsUsingBlock:^(UIView *view, NSUInteger index, BOOL *stop) {
            LCWindowGridRect tile = LCWindowGridFrameWithDividers(layout, index, self.gridProportions.rows.bytes,
                                                                  self.gridProportions.columns.bytes, self.gridProportions.lastRowColumns.bytes);
            CGRect frame = CGRectMake(bounds.origin.x + tile.x, bounds.origin.y + tile.y,
                                      tile.width, tile.height);
            DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
            [vc applyGridFrame:frame updateSceneImmediately:immediate];
        }];
    };
    if (animated) {
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.25 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:applyFrames completion:nil];
    } else {
        [UIView performWithoutAnimation:applyFrames];
    }
    self.isArrangingWindows = NO;
}

- (void)updateGridBackdrop {
    BOOL visible = NO;
    for (UIView *view in self.windowOrder.windows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (!view.hidden && view.alpha > 0 && [vc isKindOfClass:DecoratedAppSceneViewController.class] &&
            vc.isInGridLayout && !vc.appSceneVC.shouldIgnoreSceneUpdates) {
            visible = YES;
            break;
        }
    }
    self.hasVisibleGridWindows = visible;
    self.backgroundColor = visible ? UIColor.blackColor : UIColor.clearColor;
    if (!visible) [self finishGridEditing];
    [MultitaskDockManager.shared gridLayoutDidChange];
}

- (void)toggleGridDividerAdjustment {
    if (self.isAdjustingGridDividers) {
        [self finishGridDividerAdjustment];
        return;
    }
    if (!self.canAdjustGridDividers) return;
    [self arrangeWindowsInGrid];
    if (self.lastArrangedWindows.count < 2 || !self.window) return;
    self.isAdjustingGridDividers = YES;
    [self rebuildDividerHandles];
    [MultitaskDockManager.shared gridLayoutDidChange];
}

- (void)finishGridDividerAdjustment {
    if (!self.isAdjustingGridDividers) return;
    if (self.activeDivider && [self hasCurrentAdjustableGrid]) {
        [self applyCurrentGridFramesAnimated:NO updateSceneImmediately:YES];
    }
    self.isAdjustingGridDividers = NO;
    self.activeDivider = nil;
    self.dividerOverlay.hidden = YES;
    [MultitaskDockManager.shared gridLayoutDidChange];
}

- (void)finishGridEditing {
    [self finishGridDividerAdjustment];
    [self cancelGridWindowSwap];
}

- (void)beginGridWindowSwap {
    [self beginGridWindowSwapFromWindow:nil];
}

- (void)beginGridWindowSwapFromWindow:(UIView *)window {
    [self finishGridEditing];
    if (!self.canAdjustGridDividers) return;
    if (window && [self.visibleWindows indexOfObjectIdenticalTo:window] == NSNotFound) return;
    [self arrangeWindowsInGrid];
    if (![self hasCurrentAdjustableGrid]) return;
    NSArray<UIView *> *candidates = self.visibleWindows;
    if (window && [candidates indexOfObjectIdenticalTo:window] == NSNotFound) return;
    // With two windows there is only one possible pair, so exchange them immediately.
    if (candidates.count == 2) {
        [self swapGridWindow:candidates[0] withWindow:candidates[1]];
        return;
    }
    self.swapCandidates = candidates;
    self.selectedSwapWindow = window;
    self.isChoosingGridSwap = YES;
    if (!self.swapOverlay) {
        self.swapOverlay = [LCGridControlsOverlay new];
        self.swapOverlay.accessibilityViewIsModal = YES;
        __weak typeof(self) weakSelf = self;
        self.swapOverlay.escapeHandler = ^{ [weakSelf cancelGridWindowSwap]; };
        [self addSubview:self.swapOverlay];
    }
    self.swapOverlay.frame = self.lastArrangementBounds;
    self.swapOverlay.hidden = NO;
    for (UIView *view in self.swapOverlay.subviews) [view removeFromSuperview];
    for (NSUInteger index = 0; index < candidates.count; ++index) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = index;
        button.exclusiveTouch = YES;
        [button addTarget:self action:@selector(selectGridSwapWindow:) forControlEvents:UIControlEventTouchUpInside];
        [self.swapOverlay addSubview:button];
    }
    [self updateSwapTargets];
    [self bringGridControlsToFront];
    [MultitaskDockManager.shared gridLayoutDidChange];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.swapOverlay.subviews.firstObject);
}

- (void)updateSwapTargets {
    LCWindowGridLayout layout = self.gridLayout;
    for (UIButton *button in self.swapOverlay.subviews) {
        NSUInteger index = button.tag;
        UIView *window = self.swapCandidates[index];
        DecoratedAppSceneViewController *vc = (id)window._viewDelegate;
        LCWindowGridRect tile = LCWindowGridFrameWithDividers(layout, index, self.gridProportions.rows.bytes,
                                                              self.gridProportions.columns.bytes, self.gridProportions.lastRowColumns.bytes);
        button.frame = CGRectMake(tile.x, tile.y, tile.width, tile.height);
        BOOL selected = window == self.selectedSwapWindow;
        NSString *action = (selected ? @"lc.multitask.swapDeselect" :
                            self.selectedSwapWindow ? @"lc.multitask.swapHere" : @"lc.multitask.swapSelect").loc;
        NSString *title = [NSString stringWithFormat:@"%lu · %@", (unsigned long)index + 1, vc.title ?: @""];
        UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
        configuration.title = title;
        configuration.subtitle = action;
        configuration.titleLineBreakMode = NSLineBreakByTruncatingMiddle;
        configuration.baseForegroundColor = UIColor.whiteColor;
        configuration.background.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:selected ? 0.6 : 0.4];
        configuration.background.strokeColor = selected ? UIColor.systemBlueColor : [UIColor.whiteColor colorWithAlphaComponent:0.6];
        configuration.background.strokeWidth = selected ? 4 : 1;
        configuration.background.cornerRadius = 0;
        configuration.cornerStyle = UIButtonConfigurationCornerStyleFixed;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
        configuration.image = [UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"arrow.left.arrow.right"];
        configuration.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        configuration.imagePlacement = NSDirectionalRectEdgeTop;
        configuration.imagePadding = 6;
        button.configuration = configuration;
        button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, action];
        button.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    }
}

- (void)selectGridSwapWindow:(UIButton *)button {
    if (!self.isChoosingGridSwap || button.superview != self.swapOverlay) return;
    if (![self hasCurrentAdjustableGrid] || ![self.swapCandidates isEqualToArray:self.visibleWindows] ||
        button.tag < 0 || (NSUInteger)button.tag >= self.swapCandidates.count) {
        [self cancelGridWindowSwap];
        return;
    }
    UIView *window = self.swapCandidates[button.tag];
    if (self.selectedSwapWindow && self.selectedSwapWindow != window) {
        [self swapGridWindow:self.selectedSwapWindow withWindow:window];
    } else {
        self.selectedSwapWindow = self.selectedSwapWindow == window ? nil : window;
        [self updateSwapTargets];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        if (self.selectedSwapWindow) {
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"lc.multitask.swapChooseSecond".loc);
        }
    }
}

- (void)cancelGridWindowSwap {
    if (!self.isChoosingGridSwap) return;
    self.isChoosingGridSwap = NO;
    self.selectedSwapWindow = nil;
    self.swapCandidates = nil;
    self.swapOverlay.hidden = YES;
    for (UIView *view in self.swapOverlay.subviews) [view removeFromSuperview];
    [MultitaskDockManager.shared gridLayoutDidChange];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
}

- (void)swapGridWindow:(UIView *)first withWindow:(UIView *)second {
    if (![self hasCurrentAdjustableGrid]) {
        [self cancelGridWindowSwap];
        return;
    }
    NSArray<UIView *> *visible = self.visibleWindows;
    [self finishGridEditing];
    if (![self.windowOrder swapWindow:first withWindow:second visibleWindows:visible]) return;
    // The same grid configuration reuses its proportions; only the occupants change.
    [self arrangeVisibleWindowsInGrid:YES];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"lc.multitask.swapCompleted".loc);
}

- (void)undoLastGridWindowSwap {
    if (!self.canUndoGridSwap) return;
    [self finishGridEditing];
    if ([self.windowOrder undoSwapWithVisibleWindows:self.visibleWindows]) {
        [self arrangeVisibleWindowsInGrid:YES];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    }
}

- (void)resetGridProportions {
    if (!self.canAdjustGridDividers) return;
    [self arrangeWindowsInGrid];
    LCWindowGridLayout layout = self.gridLayout;
    if (layout.count < 2) return;
    LCWindowGridResetDividers(self.gridProportions.rows.mutableBytes, layout.rows);
    LCWindowGridResetDividers(self.gridProportions.columns.mutableBytes, layout.columns);
    LCWindowGridResetDividers(self.gridProportions.lastRowColumns.mutableBytes,
                               layout.count - (layout.rows - 1) * layout.columns);
    [self applyCurrentGridFramesAnimated:YES updateSceneImmediately:NO];
    [self layoutDividerHandles];
}

- (BOOL)hasCurrentAdjustableGrid {
    if (!self.window || self.gridLayout.count < 2 ||
        !CGRectEqualToRect(self.lastArrangementBounds, self.gridAvailableBounds) ||
        ![self.lastArrangedWindows isEqualToArray:self.visibleWindows]) return NO;
    for (UIView *view in self.lastArrangedWindows) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (!vc.isInGridLayout || vc.isMaximized) return NO;
    }
    return YES;
}

- (NSUInteger)columnCountForDivider:(LCGridDividerView *)divider {
    LCWindowGridLayout layout = self.gridLayout;
    return divider.dividesLastRow ? layout.count - (layout.rows - 1) * layout.columns : layout.columns;
}

- (NSMutableData *)columnFractionsForDivider:(LCGridDividerView *)divider {
    return divider.dividesLastRow ? self.gridProportions.lastRowColumns : self.gridProportions.columns;
}

- (CGPoint)positionForDivider:(LCGridDividerView *)divider {
    LCWindowGridLayout layout = self.gridLayout;
    CGPoint position = CGPointZero;
    if (divider.rowDivider >= 0) {
        position.y = LCWindowGridDividerPosition(self.gridProportions.rows.bytes, layout.rows,
                                                  divider.rowDivider, layout.height, layout.spacing);
    }
    if (divider.columnDivider >= 0) {
        position.x = LCWindowGridDividerPosition([self columnFractionsForDivider:divider].bytes,
                                                  [self columnCountForDivider:divider], divider.columnDivider,
                                                  layout.width, layout.spacing);
    }
    return position;
}

- (void)addDividerWithRow:(NSInteger)row column:(NSInteger)column lastRow:(BOOL)lastRow {
    LCGridDividerView *divider = [[LCGridDividerView alloc] initWithRow:row column:column lastRow:lastRow];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragGridDivider:)];
    pan.maximumNumberOfTouches = 1;
    [divider addGestureRecognizer:pan];
    __weak typeof(self) weakSelf = self;
    __weak LCGridDividerView *weakDivider = divider;
    divider.accessibilityAdjustment = ^(NSInteger direction) {
        [weakSelf adjustDivider:weakDivider accessibilityDirection:direction];
    };
    [self.dividerOverlay addSubview:divider];
}

- (void)rebuildDividerHandles {
    self.activeDivider = nil;
    if (!self.dividerOverlay) {
        self.dividerOverlay = [[LCGridControlsOverlay alloc] initWithFrame:self.lastArrangementBounds];
        __weak typeof(self) weakSelf = self;
        self.dividerOverlay.escapeHandler = ^{ [weakSelf finishGridDividerAdjustment]; };
        [self addSubview:self.dividerOverlay];
    }
    for (UIView *view in self.dividerOverlay.subviews) [view removeFromSuperview];
    self.dividerOverlay.hidden = NO;
    [super bringSubviewToFront:self.dividerOverlay];
    LCWindowGridLayout layout = self.gridLayout;
    for (NSUInteger row = 0; row + 1 < layout.rows; ++row) {
        [self addDividerWithRow:row column:-1 lastRow:NO];
    }
    for (NSUInteger column = 0; column + 1 < layout.columns; ++column) {
        [self addDividerWithRow:-1 column:column lastRow:NO];
    }
    size_t lastRowCount = layout.count - (layout.rows - 1) * layout.columns;
    if (lastRowCount < layout.columns) {
        for (NSUInteger column = 0; column + 1 < lastRowCount; ++column) {
            [self addDividerWithRow:-1 column:column lastRow:YES];
        }
    }
    // Put intersections above the individual lines so a diagonal drag adjusts both axes.
    for (NSUInteger row = 0; row + 1 < layout.rows; ++row) {
        for (NSUInteger column = 0; column + 1 < layout.columns; ++column) {
            [self addDividerWithRow:row column:column lastRow:NO];
        }
    }
    [self layoutDividerHandles];
}

- (void)layoutDividerHandles {
    if (!self.isAdjustingGridDividers || self.gridLayout.count < 2) return;
    LCWindowGridLayout layout = self.gridLayout;
    self.dividerOverlay.frame = self.lastArrangementBounds;
    LCWindowGridRect first = LCWindowGridFrameWithDividers(layout, 0, self.gridProportions.rows.bytes,
                                                          self.gridProportions.columns.bytes, self.gridProportions.lastRowColumns.bytes);
    LCWindowGridRect last = LCWindowGridFrameWithDividers(layout, (layout.rows - 1) * layout.columns,
                                                         self.gridProportions.rows.bytes, self.gridProportions.columns.bytes,
                                                         self.gridProportions.lastRowColumns.bytes);
    BOOL partialRow = layout.count % layout.columns != 0;
    for (LCGridDividerView *divider in self.dividerOverlay.subviews) {
        CGPoint position = [self positionForDivider:divider];
        BOOL intersection = divider.rowDivider >= 0 && divider.columnDivider >= 0;
        if (intersection) {
            divider.frame = CGRectMake(position.x - 22, position.y - 22, 44, 44);
            divider.gripPosition = CGPointMake(22, 22);
        } else if (divider.rowDivider >= 0) {
            divider.frame = CGRectMake(0, position.y - 22, layout.width, 44);
            divider.gripPosition = CGPointMake(first.width / 2, 22);
        } else {
            CGFloat top = divider.dividesLastRow ? last.y : 0;
            CGFloat bottom = divider.dividesLastRow || !partialRow ? layout.height : last.y - layout.spacing / 2;
            divider.frame = CGRectMake(position.x - 22, top, 44, bottom - top);
            divider.gripPosition = CGPointMake(22, divider.dividesLastRow ? last.height / 2 : first.height / 2);
        }
        if (!intersection) {
            NSUInteger tracks = divider.rowDivider >= 0 ? layout.rows : [self columnCountForDivider:divider];
            NSUInteger index = divider.rowDivider >= 0 ? divider.rowDivider : divider.columnDivider;
            const double *fractions = divider.rowDivider >= 0 ? self.gridProportions.rows.bytes : [self columnFractionsForDivider:divider].bytes;
            double start = LCWindowGridBoundary(fractions, tracks, index);
            double split = LCWindowGridBoundary(fractions, tracks, index + 1);
            double end = LCWindowGridBoundary(fractions, tracks, index + 2);
            double percent = (split - start) / (end - start) * 100;
            divider.accessibilityValue = [NSString stringWithFormat:@"%.0f%% / %.0f%%", percent, 100 - percent];
        }
        [divider setNeedsLayout];
        [divider layoutIfNeeded];
    }
}

- (BOOL)moveDivider:(LCGridDividerView *)divider toPosition:(CGPoint)position {
    LCWindowGridLayout layout = self.gridLayout;
    BOOL changed = NO;
    if (divider.rowDivider >= 0) {
        changed |= LCWindowGridMoveDivider(self.gridProportions.rows.mutableBytes, layout.rows, divider.rowDivider,
                                            position.y, layout.height, layout.spacing, LCWindowGridMinimumHeight);
    }
    if (divider.columnDivider >= 0) {
        changed |= LCWindowGridMoveDivider([self columnFractionsForDivider:divider].mutableBytes,
                                            [self columnCountForDivider:divider], divider.columnDivider,
                                            position.x, layout.width, layout.spacing, LCWindowGridMinimumWidth);
    }
    return changed;
}

- (void)dragGridDivider:(UIPanGestureRecognizer *)gesture {
    LCGridDividerView *divider = (id)gesture.view;
    if (!self.isAdjustingGridDividers || self.isArrangingWindows || divider.superview != self.dividerOverlay) return;
    if (![self hasCurrentAdjustableGrid]) {
        [self finishGridDividerAdjustment];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (self.activeDivider && self.activeDivider != divider) return;
        self.activeDivider = divider;
        self.dragStartDividerPosition = [self positionForDivider:divider];
        self.lastInteractiveSceneUpdate = 0;
        for (UIView *view in self.lastArrangedWindows) [view.layer removeAllAnimations];
    }
    if (self.activeDivider != divider) return;
    CGPoint translation = [gesture translationInView:self];
    CGPoint position = CGPointMake(self.dragStartDividerPosition.x + translation.x, self.dragStartDividerPosition.y + translation.y);
    BOOL changed = [self moveDivider:divider toPosition:position];
    BOOL finished = gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled;
    CFTimeInterval now = CACurrentMediaTime();
    // Resize window frames with the finger, but limit expensive guest scene updates to 20 Hz.
    BOOL updateScene = finished || now - self.lastInteractiveSceneUpdate >= 0.05;
    if (changed || finished) {
        [self applyCurrentGridFramesAnimated:NO updateSceneImmediately:updateScene];
        [self layoutDividerHandles];
        if (updateScene) self.lastInteractiveSceneUpdate = now;
    }
    if (finished) self.activeDivider = nil;
}

- (void)adjustDivider:(LCGridDividerView *)divider accessibilityDirection:(NSInteger)direction {
    if (!divider || !self.isAdjustingGridDividers || ![self hasCurrentAdjustableGrid]) return;
    CGPoint position = [self positionForDivider:divider];
    position.x += direction * self.gridLayout.width * 0.05;
    position.y += direction * self.gridLayout.height * 0.05;
    if ([self moveDivider:divider toPosition:position]) {
        [self applyCurrentGridFramesAnimated:NO updateSceneImmediately:YES];
        [self layoutDividerHandles];
    }
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // Skip divider overlays and find the frontmost visible app window.
    for (UIView *view in self.subviews.reverseObjectEnumerator) {
        DecoratedAppSceneViewController *vc = (id)view._viewDelegate;
        if (!view.hidden && view.alpha > 0 && [vc isKindOfClass:DecoratedAppSceneViewController.class] &&
            !vc.appSceneVC.shouldIgnoreSceneUpdates) {
            [vc.appSceneVC handleStatusBarTapAction:action];
            return YES;
        }
    }
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        // Grid separators and safe-area padding should not activate the host UI underneath.
        return self.hasVisibleGridWindows ? self : nil;
    } else {
        self.shouldForwardTapAction = !((self.dividerOverlay && [hitView isDescendantOfView:self.dividerOverlay]) ||
                                        (self.swapOverlay && [hitView isDescendantOfView:self.swapOverlay]));
        return hitView;
    }
}
@end
