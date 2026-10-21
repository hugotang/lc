#import "../LiveContainer/LCWorkspaceLaunch.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSString *scheme = @"livecontainer";
        NSURL *url = LCWorkspaceRestoreURL(scheme);
        assert([url.absoluteString isEqualToString:@"livecontainer://workspace-restore"]);
        assert(LCIsWorkspaceRestoreURL(url, scheme));
        assert(LCIsWorkspaceRestoreURL([NSURL URLWithString:@"LIVECONTAINER://WORKSPACE-RESTORE/"], scheme));
        assert(LCIsWorkspaceRestoreURL(LCWorkspaceRestoreURL(@"my-livecontainer.2"), @"my-livecontainer.2"));
        assert(!LCIsWorkspaceRestoreURL(url, @"livecontainer2"));
        assert(!LCIsWorkspaceRestoreURL(nil, scheme));
        assert(!LCIsWorkspaceRestoreURL(url, nil));
        assert(LCWorkspaceRestoreURL(nil) == nil);
        assert(LCWorkspaceRestoreURL(@"") == nil);
        assert(LCWorkspaceRestoreURL(@"bad scheme") == nil);

        // Never interpret a web link, guest launch, snapshot, credentials or unknown path as restore.
        for (NSString *value in @[
            @"https://workspace-restore", @"livecontainer2://workspace-restore",
            @"livecontainer://livecontainer-launch?bundle-name=Notes.app",
            @"livecontainer://workspace-restore/other",
            @"livecontainer://workspace-restore?bundle-name=Notes.app",
            @"livecontainer://workspace-restore?workspace=untrusted",
            @"livecontainer://workspace-restore#restore",
            @"livecontainer://user@workspace-restore",
            @"livecontainer://user:password@workspace-restore",
            @"livecontainer://workspace-restore:123"
        ]) {
            assert(!LCIsWorkspaceRestoreURL([NSURL URLWithString:value], scheme));
        }

        NSString *suite = [@"LCWorkspaceRestoreTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:10000];
        [defaults setObject:@"keep" forKey:@"unrelated"];
        LCQueueWorkspaceRestore(defaults, scheme, now);
        NSURL *restored = LCConsumePendingWorkspaceRestore(defaults, scheme, [now dateByAddingTimeInterval:1]);
        assert([restored isEqual:url]);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
        assert([[defaults stringForKey:@"unrelated"] isEqualToString:@"keep"]);

        // Coalesce repeated requests and consume the latest once.
        LCQueueWorkspaceRestore(defaults, scheme, [now dateByAddingTimeInterval:-121]);
        LCQueueWorkspaceRestore(defaults, scheme, now);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) != nil);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);

        LCQueueWorkspaceRestore(defaults, scheme, [now dateByAddingTimeInterval:-120]);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) != nil);
        for (NSTimeInterval offset = -121; offset <= 121; offset += 242) {
            LCQueueWorkspaceRestore(defaults, scheme, [now dateByAddingTimeInterval:offset]);
            assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
            assert([defaults objectForKey:@"LCPendingWorkspaceRestore"] == nil);
        }
        LCQueueWorkspaceRestore(defaults, scheme, now);
        assert(LCConsumePendingWorkspaceRestore(defaults, @"another-lc", now) == nil);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
        LCQueueWorkspaceRestore(defaults, scheme, now);
        LCClearPendingWorkspaceRestore(defaults);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);

        for (id stored in @[
            @"bad", @[], @{}, @{@"url": url.absoluteString},
            @{@"url": @1, @"date": now}, @{@"url": url.absoluteString, @"date": @"bad"},
            @{@"url": @"livecontainer://workspace-restore?workspace=untrusted", @"date": now}
        ]) {
            [defaults setObject:stored forKey:@"LCPendingWorkspaceRestore"];
            assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
            assert([defaults objectForKey:@"LCPendingWorkspaceRestore"] == nil);
        }
        [defaults removePersistentDomainForName:suite];
        puts("Workspace restore request tests passed (URL validation, custom schemes, single consumption, expiry and corrupt requests).");
    }
    return 0;
}
