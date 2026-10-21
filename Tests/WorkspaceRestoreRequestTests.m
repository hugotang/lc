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

        NSString *identifier = NSUUID.UUID.UUIDString.lowercaseString;
        NSURL *namedURL = LCWorkspaceRestoreURLForIdentifier(scheme, identifier.uppercaseString);
        assert(LCIsWorkspaceRestoreURL(namedURL, scheme));
        assert([namedURL.absoluteString isEqualToString:[@"livecontainer://workspace-restore?id=" stringByAppendingString:identifier]]);
        assert([LCWorkspaceRestoreIdentifier(namedURL, scheme) isEqualToString:identifier]);
        assert(LCWorkspaceRestoreIdentifier(url, scheme) == nil);
        assert(LCWorkspaceRestoreIdentifier(namedURL, @"another-lc") == nil);
        assert(LCWorkspaceRestoreURLForIdentifier(@"my-livecontainer.2", identifier) != nil);
        assert(LCWorkspaceRestoreURLForIdentifier(@"bad scheme", identifier) == nil);
        assert(LCWorkspaceRestoreURLForIdentifier(scheme, @"bad") == nil);
        for (NSString *query in @[@"", @"id", @"id=", @"id=bad", @"id=../../other",
                                  [NSString stringWithFormat:@"id=%@&id=%@", identifier, identifier],
                                  [NSString stringWithFormat:@"id=%@&bundle-name=Game.app", identifier],
                                  [NSString stringWithFormat:@"other=%@", identifier]]) {
            NSURL *invalid = [NSURL URLWithString:[@"livecontainer://workspace-restore?" stringByAppendingString:query]];
            assert(!LCIsWorkspaceRestoreURL(invalid, scheme));
        }

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

        // A confirmed guest-to-host switch must retain the exact workspace selection.
        LCQueueWorkspaceRestoreURL(defaults, namedURL, scheme, now);
        restored = LCConsumePendingWorkspaceRestore(defaults, scheme, now);
        assert([LCWorkspaceRestoreIdentifier(restored, scheme) isEqualToString:identifier]);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
        NSURL *secondURL = LCWorkspaceRestoreURLForIdentifier(scheme, NSUUID.UUID.UUIDString);
        LCQueueWorkspaceRestoreURL(defaults, namedURL, scheme, now);
        LCQueueWorkspaceRestoreURL(defaults, secondURL, scheme, now);
        assert([LCConsumePendingWorkspaceRestore(defaults, scheme, now) isEqual:secondURL]);
        LCQueueWorkspaceRestoreURL(defaults, namedURL, scheme, [now dateByAddingTimeInterval:-121]);
        assert(LCConsumePendingWorkspaceRestore(defaults, scheme, now) == nil);
        LCQueueWorkspaceRestoreURL(defaults, namedURL, scheme, now);
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
        puts("Workspace restore request tests passed (named and legacy URLs, custom schemes, single consumption, expiry and corrupt requests).");
    }
    return 0;
}
