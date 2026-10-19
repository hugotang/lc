//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;
#import "WindowWorkspace.h"
@class DecoratedAppSceneViewController;

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
- (LCWindowWorkspace * _Nullable)captureWorkspace NS_SWIFT_NAME(captureWorkspace());
- (void)applyWorkspace:(LCWindowWorkspace * _Nonnull)workspace NS_SWIFT_NAME(applyWorkspace(_:));
- (DecoratedAppSceneViewController * _Nullable)windowForContainer:(NSString * _Nonnull)dataUUID NS_SWIFT_NAME(window(forContainer:));
- (CGRect)frameByAvoidingKeyboard:(CGRect)frame forWindow:(DecoratedAppSceneViewController * _Nonnull)window;
- (void)forgetKeyboardFrameForWindow:(UIView * _Nonnull)window;
- (CGRect)unobscuredFrameForWindow:(UIView * _Nonnull)window;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end
