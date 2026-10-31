#import "../MultitaskSupport/TapSyncSelection.h"
#include <assert.h>
#include <stdio.h>

static NSString *const sourceID = @"11111111-1111-4111-8111-111111111111";
static NSString *const targetID = @"22222222-2222-4222-8222-222222222222";

static void testRoundTripAndEdits(NSUserDefaults *defaults) {
    LCTapSyncSelectionStore *store = [[LCTapSyncSelectionStore alloc] initWithDefaults:defaults];
    LCTapSyncSelection *initial = store.loadSelection;
    assert(initial.source == nil && initial.targets.count == 0 && initial.mode == LCTapSyncModeTapsOnly);
    [defaults setBool:YES forKey:@"LCTapSyncCompactControls"];
    [defaults setObject:@{@"x": @0.25, @"y": @0.75} forKey:@"LCTapSyncControlsPortraitPosition"];
    for (LCTapSyncMode mode = LCTapSyncModeTapsOnly; mode <= LCTapSyncModeTwoFingers; mode++) {
        NSArray *members = @[targetID, @"third-account", @"fourth-account"];
        LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithSource:sourceID targets:members mode:mode];
        [store saveSelection:selection];
        // Reopening the settings store has no dependency on live window numbers or running accounts.
        LCTapSyncSelectionStore *reopened = [[LCTapSyncSelectionStore alloc] initWithDefaults:defaults];
        LCTapSyncSelection *loaded = reopened.loadSelection;
        assert([loaded.source isEqual:sourceID] && [loaded.targets isEqual:members] && loaded.mode == mode);
        assert([defaults integerForKey:@"LCTapSyncMode"] == mode);
        NSSet *keys = [NSSet setWithArray:[[defaults dictionaryForKey:@"LCTapSyncLastSelection"] allKeys]];
        assert(([keys isEqual:[NSSet setWithArray:@[@"version", @"source", @"targets", @"mode"]]]));

        LCTapSyncSelection *withoutOneFollower = [[LCTapSyncSelection alloc] initWithSource:loaded.source
            targets:@[targetID, @"fourth-account"] mode:loaded.mode];
        [reopened saveSelection:withoutOneFollower];
        assert(([[store loadSelection].targets isEqual:@[targetID, @"fourth-account"]]));
    }
    // Incomplete choices and cleared groups must replace older complete groups on relaunch.
    [store saveSelection:[[LCTapSyncSelection alloc] initWithSource:sourceID targets:@[] mode:LCTapSyncModeSingleFinger]];
    LCTapSyncSelection *sourceOnly = store.loadSelection;
    assert([sourceOnly.source isEqual:sourceID] && sourceOnly.targets.count == 0);
    assert(sourceOnly.mode == LCTapSyncModeSingleFinger && sourceOnly.groupPropertyList.count == 0);
    [store saveSelection:[[LCTapSyncSelection alloc] initWithSource:nil targets:@[targetID] mode:sourceOnly.mode]];
    LCTapSyncSelection *cleared = store.loadSelection;
    assert(cleared.source == nil && cleared.targets.count == 0 && cleared.mode == LCTapSyncModeSingleFinger);
    assert([defaults boolForKey:@"LCTapSyncCompactControls"]);
    assert(([[defaults dictionaryForKey:@"LCTapSyncControlsPortraitPosition"] isEqual:@{@"x": @0.25, @"y": @0.75}]));
}

static void testWorkspaceReplacement(NSUserDefaults *defaults) {
    LCTapSyncSelectionStore *store = [[LCTapSyncSelectionStore alloc] initWithDefaults:defaults];
    NSDictionary *workspace = @{@"source": @"workspace-account", @"targets": @[sourceID, targetID], @"mode": @"twoFingers"};
    LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithGroupPropertyList:workspace];
    assert([selection.groupPropertyList isEqual:workspace]);
    [store saveSelection:selection];
    assert([[store loadSelection].groupPropertyList isEqual:workspace]);
    // A workspace without a sync group clears the last group and restores tap-only behavior.
    [store saveSelection:[[LCTapSyncSelection alloc] initWithGroupPropertyList:@{}]];
    assert([store loadSelection].source == nil && [store loadSelection].mode == LCTapSyncModeTapsOnly);
    LCTapSyncSelection *oldWorkspace = [[LCTapSyncSelection alloc] initWithGroupPropertyList:
        @{@"source": sourceID, @"targets": @[targetID], @"mode": @"unknown-future-mode"}];
    assert(oldWorkspace.mode == LCTapSyncModeTapsOnly);
    assert((![oldWorkspace.groupPropertyList.allKeys containsObject:@"mode"]));
}

static void testValidationAndMigration(NSUserDefaults *defaults) {
    LCTapSyncSelectionStore *store = [[LCTapSyncSelectionStore alloc] initWithDefaults:defaults];
    [defaults removeObjectForKey:@"LCTapSyncLastSelection"];
    for (LCTapSyncMode mode = LCTapSyncModeTapsOnly; mode <= LCTapSyncModeTwoFingers; mode++) {
        [defaults setInteger:mode forKey:@"LCTapSyncMode"];
        assert([store loadSelection].mode == mode && [store loadSelection].source == nil);
    }
    for (id badMode in @[@-1, @42, @1.5, @"1", @[], @{}]) {
        [defaults setObject:badMode forKey:@"LCTapSyncMode"];
        assert([store loadSelection].mode == LCTapSyncModeTapsOnly);
    }
    LCTapSyncSelection *deduplicated = [[LCTapSyncSelection alloc] initWithSource:sourceID
        targets:@[sourceID, targetID, targetID, @"third-account"] mode:LCTapSyncModeTwoFingers];
    assert(([deduplicated.targets isEqual:@[targetID, @"third-account"]]));

    NSString *tooLong = [@"x" stringByPaddingToLength:1025 withString:@"x" startingAtIndex:0];
    for (id badSource in @[@42, NSNull.null, @[], @{}, @"", @".", @"..", @"a/b", @"a\\b", @"a\nb", tooLong]) {
        LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithGroupPropertyList:
            @{@"source": badSource, @"targets": @[targetID], @"mode": @"twoFingers"}];
        assert(selection.source == nil && selection.targets.count == 0);
    }
    for (id badTargets in @[@42, @{}, NSNull.null, @[targetID, @42], @[targetID, @"a/b"]]) {
        LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithGroupPropertyList:
            @{@"source": sourceID, @"targets": badTargets}];
        assert([selection.source isEqual:sourceID] && selection.targets.count == 0);
    }
    NSMutableArray *oversized = [NSMutableArray array];
    for (unsigned i = 0; i < 64; i++) [oversized addObject:[NSString stringWithFormat:@"account-%u", i]];
    LCTapSyncSelection *selection = [[LCTapSyncSelection alloc] initWithSource:sourceID targets:oversized mode:99];
    assert(selection.targets.count == 0 && selection.mode == LCTapSyncModeTapsOnly);
    for (id malformed in @[@42, @[], @"bad", @{@"version": @999, @"source": sourceID, @"targets": @[targetID]}]) {
        [defaults setObject:malformed forKey:@"LCTapSyncLastSelection"];
        assert([store loadSelection].source == nil);
    }
    [defaults setObject:@{@"version": @1, @"source": sourceID, @"targets": @[targetID], @"mode": @42}
                 forKey:@"LCTapSyncLastSelection"];
    assert([store loadSelection].mode == LCTapSyncModeTapsOnly);
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"lc-tests.tap-sync-selection." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        testRoundTripAndEdits(defaults);
        testWorkspaceReplacement(defaults);
        testValidationAndMigration(defaults);
        [defaults removePersistentDomainForName:suite];
        puts("Tap sync selection tests passed");
    }
    return 0;
}
