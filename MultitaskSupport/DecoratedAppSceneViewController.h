#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView *resizeHandle;
@property(nonatomic) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) BOOL isInGridLayout;
@property(nonatomic, readonly) BOOL isAppTerminated;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)minimizeWindow;
- (void)closeWindow;
- (void)maximizeWindow;
- (void)updateContentScale:(CGFloat)scale;
- (void)togglePictureInPicture;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)applyGridFrame:(CGRect)frame;
- (void)applyGridFrame:(CGRect)frame updateSceneImmediately:(BOOL)immediate;
- (void)updateVerticalConstraints;
- (void)updateAccountTitle;
- (void)updateFrameForKeyboard;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end

