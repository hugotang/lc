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
- (void)arrangeWindowsInGrid;
- (void)setNeedsGridLayout;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end
