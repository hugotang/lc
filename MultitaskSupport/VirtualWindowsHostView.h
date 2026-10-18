//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;

API_AVAILABLE(ios(16.0))
@interface VirtualWindowsHostView: UIView
@property(nonatomic) BOOL shouldForwardTapAction;
@property(nonatomic, readonly) BOOL automaticallyTilesWindows;
@property(nonatomic, readonly) BOOL shouldHideGridWindowBars;
@property(nonatomic, readonly) BOOL hasVisibleGridWindows;
@property(nonatomic, readonly) BOOL canAdjustGridDividers;
@property(nonatomic, readonly) BOOL isAdjustingGridDividers;
@property(nonatomic, readonly) BOOL isChoosingGridSwap;
@property(nonatomic, readonly) BOOL canUndoGridSwap;
- (void)arrangeWindowsInGrid;
- (void)setNeedsGridLayout;
- (void)toggleGridDividerAdjustment;
- (void)finishGridDividerAdjustment;
- (void)resetGridProportions;
- (void)beginGridWindowSwap;
- (void)beginGridWindowSwapFromWindow:(UIView * _Nullable)window NS_SWIFT_NAME(beginGridWindowSwap(from:));
- (void)cancelGridWindowSwap;
- (void)undoLastGridWindowSwap;
- (void)finishGridEditing;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end
