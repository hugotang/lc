#import "../MultitaskSupport/WorkspaceLaunchLayout.h"
#include <assert.h>
#include <stdio.h>

@interface LCWorkspaceLaunchTestWindow : NSObject
@property(nonatomic, copy) NSString *bundleName, *dataUUID;
@end
@implementation LCWorkspaceLaunchTestWindow
// Views must be placed by identity even when their game/account labels compare equal.
- (BOOL)isEqual:(id)object { return [object isKindOfClass:self.class]; }
- (NSUInteger)hash { return 1; }
@end

static LCWorkspaceLaunchTestWindow *window(NSString *bundle, NSString *container) {
    LCWorkspaceLaunchTestWindow *view = [LCWorkspaceLaunchTestWindow new];
    view.bundleName = bundle;
    view.dataUUID = container;
    return view;
}

static LCWindowWorkspace *workspace(void) {
    NSMutableArray *entries = [NSMutableArray array];
    double scales[] = {0.5, 1, 1.5, 2};
    for (NSUInteger index = 0; index < 4; index++) {
        [entries addObject:[[LCWorkspaceWindow alloc] initWithBundleName:@"game.app"
            dataUUID:[NSString stringWithFormat:@"account-%lu", (unsigned long)index] scale:scales[index]]];
    }
    return [[LCWindowWorkspace alloc] initWithWindows:entries proportions:@{} singleRowInLandscape:YES];
}

static NSArray *slots(LCWorkspaceLaunchLayout *plan, NSArray *views) {
    return [plan slotsForWindows:views matchingEntry:^BOOL(id object, LCWorkspaceWindow *entry) {
        LCWorkspaceLaunchTestWindow *view = object;
        return [view.bundleName isEqualToString:entry.bundleName] && [view.dataUUID isEqualToString:entry.dataUUID];
    }];
}

static void testAllFourAccountLaunchOrders(void) {
    LCWorkspaceLaunchLayout *plan = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:workspace()];
    NSArray *views = @[window(@"game.app", @"account-0"), window(@"game.app", @"account-1"),
                       window(@"game.app", @"account-2"), window(@"game.app", @"account-3")];
    assert(slots(plan, @[]).count == 4);
    for (NSUInteger a = 0; a < 4; a++) for (NSUInteger b = 0; b < 4; b++) {
        if (b == a) continue;
        for (NSUInteger c = 0; c < 4; c++) {
            if (c == a || c == b) continue;
            NSUInteger d = 6 - a - b - c;
            NSArray *order = @[views[a], views[b], views[c], views[d]];
            NSMutableArray *opened = [NSMutableArray array];
            for (id view in order) {
                [opened addObject:view];
                NSArray *placed = slots(plan, opened);
                assert(placed.count == 4);
                for (NSUInteger index = 0; index < 4; index++) {
                    BOOL started = [opened indexOfObjectIdenticalTo:views[index]] != NSNotFound;
                    assert(placed[index] == (started ? views[index] : NSNull.null));
                }
            }
        }
    }
}

static void testUnrelatedAndMismatchedWindows(void) {
    LCWorkspaceLaunchLayout *plan = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:workspace()];
    id source = window(@"game.app", @"account-2");
    id otherApp = window(@"another.app", @"account-0"), otherAccount = window(@"game.app", @"unsaved");
    NSArray *placed = slots(plan, @[otherApp, source, otherAccount, source]);
    assert(placed.count == 6);
    assert(placed[0] == NSNull.null && placed[1] == NSNull.null && placed[2] == source && placed[3] == NSNull.null);
    assert(placed[4] == otherApp && placed[5] == otherAccount);
    id replacement = window(@"game.app", @"account-2");
    assert(slots(plan, @[otherAccount, replacement])[2] == replacement);
    assert(slots(plan, @[otherAccount])[2] == NSNull.null);
}

static void testSavedScaleAndSnapshotStayBoundToAccount(void) {
    LCWindowWorkspace *snapshot = workspace();
    NSDictionary *original = snapshot.propertyList;
    LCWorkspaceLaunchLayout *plan = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:snapshot];
    for (LCWorkspaceWindow *entry in snapshot.windows) {
        assert([plan entryForBundleName:entry.bundleName dataUUID:entry.dataUUID] == entry);
    }
    assert([plan entryForBundleName:@"another.app" dataUUID:@"account-0"] == nil);
    assert([plan entryForBundleName:@"game.app" dataUUID:@"missing"] == nil);
    assert([plan entryForBundleName:@"game.app" dataUUID:@"account-0"].scale == 0.5);
    assert([plan entryForBundleName:@"game.app" dataUUID:@"account-3"].scale == 2);
    (void)slots(plan, @[window(@"game.app", @"account-3")]);
    assert([snapshot.propertyList isEqual:original]);
}

static void testNewRestorePlanHasNoPreviousReservations(void) {
    LCWindowWorkspace *snapshot = workspace();
    LCWorkspaceLaunchLayout *old = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:snapshot];
    assert(slots(old, @[]).count == 4);
    LCWindowWorkspace *partial = [[LCWindowWorkspace alloc] initWithWindows:@[snapshot.windows[2]] proportions:@{}
                                                   singleRowInLandscape:NO];
    LCWorkspaceLaunchLayout *next = [[LCWorkspaceLaunchLayout alloc] initWithWorkspace:partial];
    id restored = window(@"game.app", @"account-2");
    NSArray *placed = slots(next, @[restored]);
    assert(placed.count == 1 && placed[0] == restored);
    assert([next entryForBundleName:@"game.app" dataUUID:@"account-0"] == nil);
    assert(slots(old, @[]).count == 4);
}

int main(void) {
    @autoreleasepool {
        testAllFourAccountLaunchOrders();
        testUnrelatedAndMismatchedWindows();
        testSavedScaleAndSnapshotStayBoundToAccount();
        testNewRestorePlanHasNoPreviousReservations();
        puts("Workspace launch slots passed (24 launch orders, identity, saved scales, unrelated and replacement windows).");
    }
    return 0;
}
