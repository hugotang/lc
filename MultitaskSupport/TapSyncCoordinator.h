#import <UIKit/UIKit.h>
#import "WindowWorkspace.h"
#import "TapSyncPeer.h"

NS_ASSUME_NONNULL_BEGIN
@class AppSceneViewController, VirtualWindowsHostView;
FOUNDATION_EXPORT NSNotificationName const LCTapSyncDidChangeNotification;

API_AVAILABLE(ios(16.0))
@interface LCTapSyncCoordinator : NSObject
@property(class, nonatomic, readonly) LCTapSyncCoordinator *shared;
@property(nonatomic, weak) VirtualWindowsHostView *host;
@property(nonatomic, copy, readonly, nullable) NSString *sourceContainer;
@property(nonatomic, copy, readonly) NSArray<NSString *> *targetContainers;
@property(nonatomic, readonly, getter=isActive) BOOL active;
@property(nonatomic, readonly, getter=isStarting) BOOL starting;
@property(nonatomic, readonly) NSUInteger forwardedTapCount;
@property(nonatomic, copy, readonly) NSString *statusKey;
@property(nonatomic, copy, readonly) NSArray<LCWorkspaceWindow *> *availableWindows;
@property(nonatomic, copy, readonly) NSDictionary *selectionPropertyList;
@property(nonatomic, readonly) BOOL canStart;
- (BOOL)isReadyForContainer:(NSString *)container NS_SWIFT_NAME(isReady(forContainer:));
- (BOOL)canReplayForContainer:(NSString *)container NS_SWIFT_NAME(canReplay(forContainer:));
- (void)registerScene:(AppSceneViewController *)scene;
- (void)unregisterScene:(AppSceneViewController *)scene;
- (void)selectSource:(nullable NSString *)source targets:(NSArray<NSString *> *)targets;
- (void)restoreSelection:(NSDictionary *)selection;
- (void)start;
- (void)pause;
- (void)pauseForWindowChange;
- (void)validateWindows;
@end
NS_ASSUME_NONNULL_END
