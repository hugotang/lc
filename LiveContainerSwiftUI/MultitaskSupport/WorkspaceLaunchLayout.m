#import "WorkspaceLaunchLayout.h"

@implementation LCWorkspaceLaunchLayout
- (instancetype)initWithWorkspace:(LCWindowWorkspace *)workspace {
    if ((self = [super init])) _workspace = workspace;
    return self;
}
- (LCWorkspaceWindow *)entryForBundleName:(NSString *)bundleName dataUUID:(NSString *)dataUUID {
    for (LCWorkspaceWindow *entry in self.workspace.windows) {
        if ([entry.bundleName isEqualToString:bundleName] && [entry.dataUUID isEqualToString:dataUUID]) return entry;
    }
    return nil;
}
- (NSArray *)slotsForWindows:(NSArray *)windows matchingEntry:(BOOL (^)(id, LCWorkspaceWindow *))matches {
    NSMutableArray *slots = [NSMutableArray array];
    NSMutableArray *placed = [NSMutableArray array];
    for (LCWorkspaceWindow *entry in self.workspace.windows) {
        id found = nil;
        for (id window in windows) {
            if ([placed indexOfObjectIdenticalTo:window] == NSNotFound && matches(window, entry)) {
                found = window;
                break;
            }
        }
        [slots addObject:found ?: NSNull.null];
        if (found) [placed addObject:found];
    }
    // Unrelated open windows keep their relative order after the saved accounts.
    for (id window in windows) {
        if ([placed indexOfObjectIdenticalTo:window] == NSNotFound) {
            [slots addObject:window];
            [placed addObject:window];
        }
    }
    return slots.copy;
}
@end
