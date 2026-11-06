#import "WindowWorkspace.h"

NS_ASSUME_NONNULL_BEGIN

// Reserve the saved slots while accounts are still starting. Missing slots use
// NSNull, so a newly launched game never receives a one/two/three-window tile.
@interface LCWorkspaceLaunchLayout : NSObject
@property(nonatomic, strong, readonly) LCWindowWorkspace *workspace;
- (instancetype)initWithWorkspace:(LCWindowWorkspace *)workspace;
- (nullable LCWorkspaceWindow *)entryForBundleName:(NSString *)bundleName dataUUID:(NSString *)dataUUID;
- (NSArray *)slotsForWindows:(NSArray *)windows
               matchingEntry:(BOOL (^)(id window, LCWorkspaceWindow *entry))matches;
@end

NS_ASSUME_NONNULL_END
