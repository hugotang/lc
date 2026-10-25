#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Ordinary minimization is separate from PiP and termination. Geometry and stacking stay in the view.
@interface LCWindowMinimization : NSObject
@property(nonatomic, weak, readonly, nullable) UIView *view;
@property(nonatomic, readonly, getter=isMinimized) BOOL minimized;
@property(nonatomic, readonly) BOOL canRestore;
- (instancetype)initWithView:(UIView *)view availability:(BOOL (^)(void))availability;
- (BOOL)minimize;
- (BOOL)restore;
// A different presentation path owns the view from here; pending minimize completions must not hide it.
- (void)invalidate;
// Restore visibility for the whole eligible set before the host updates chrome and layout once.
+ (NSUInteger)restoreWindows:(NSArray<LCWindowMinimization *> *)windows
                      inHost:(UIView *)host layout:(void (^)(NSArray<UIView *> *restored))layout;
@end

NS_ASSUME_NONNULL_END
