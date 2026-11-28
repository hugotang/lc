#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Grid order is independent of focus (UIView stacking order). Hidden windows keep their place.
@interface LCWindowGridOrder : NSObject
@property(nonatomic, copy, readonly) NSArray *windows;
- (void)addWindow:(id)window;
- (void)removeWindow:(id)window;
- (BOOL)swapWindow:(nullable id)first withWindow:(nullable id)second visibleWindows:(NSArray *)visibleWindows;
- (BOOL)canUndoSwapWithVisibleWindows:(NSArray *)visibleWindows;
- (BOOL)undoSwapWithVisibleWindows:(NSArray *)visibleWindows;
// Move known windows to the beginning in the supplied order; retain all other windows.
- (void)restoreOrderWithWindows:(NSArray *)windows;
@end

NS_ASSUME_NONNULL_END
