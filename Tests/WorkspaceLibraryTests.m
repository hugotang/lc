#import "../MultitaskSupport/WindowWorkspace.h"
#import "../LiveContainer/LCWorkspaceLaunch.h"
#include <assert.h>
#include <stdio.h>

static LCWindowWorkspace *snapshot(NSString *container, BOOL singleRow) {
    LCWorkspaceWindow *window = [[LCWorkspaceWindow alloc] initWithBundleName:@"Game.app" dataUUID:container scale:1.25];
    NSDictionary *grid = @{@"rows": @[], @"columns": @[], @"lastRowColumns": @[]};
    return [[LCWindowWorkspace alloc] initWithWindows:@[window] proportions:@{@"1:1:1:0": grid} singleRowInLandscape:singleRow];
}

static LCWorkspaceLibrary *openLibrary(NSUserDefaults *defaults) {
    return [[LCWorkspaceLibrary alloc] initWithDefaults:defaults legacyName:@"Original Workspace"];
}

static void testMigrationAndNamedLinks(NSUserDefaults *defaults) {
    LCWindowWorkspace *original = snapshot(@"A", YES);
    NSMutableDictionary *legacy = original.propertyList.mutableCopy;
    [legacy removeObjectForKey:@"reservePortraitTop"];
    [legacy removeObjectForKey:@"reservePortraitBottom"];
    [defaults setObject:legacy forKey:@"LCWindowWorkspace"];
    [defaults setObject:@"keep" forKey:@"unrelated"];
    LCWorkspaceLibrary *library = openLibrary(defaults);
    assert(library.workspaces.count == 1);
    LCNamedWorkspace *migrated = library.workspaces.firstObject;
    assert([migrated.name isEqualToString:@"Original Workspace"]);
    assert([migrated.snapshot.propertyList isEqual:original.propertyList]);
    assert(migrated.snapshot.reservePortraitTop && !migrated.snapshot.reservePortraitBottom);
    NSString *originalID = migrated.identifier;
    NSURL *link = LCWorkspaceRestoreURLForIdentifier(@"livecontainer", originalID);
    assert(link && [LCWorkspaceRestoreIdentifier(link, @"livecontainer") isEqualToString:originalID]);

    // Reopening, including after a locale change, must not import the old save twice.
    library = [[LCWorkspaceLibrary alloc] initWithDefaults:defaults legacyName:@"Different Language"];
    assert(library.workspaces.count == 1);
    assert([library.workspaces.firstObject.identifier isEqualToString:originalID]);
    assert([library.workspaces.firstObject.name isEqualToString:migrated.name]);

    LCWindowWorkspace *musicSnapshot = snapshot(@"B", NO);
    musicSnapshot = [[LCWindowWorkspace alloc] initWithWindows:musicSnapshot.windows proportions:musicSnapshot.proportions
        singleRowInLandscape:NO reservePortraitTop:NO reservePortraitBottom:YES];
    LCNamedWorkspace *music = [library saveWorkspace:musicSnapshot name:@"Music" replacingIdentifier:nil];
    assert(music && library.workspaces.count == 2);
    assert(![music.identifier isEqualToString:originalID]);
    NSURL *musicLink = LCWorkspaceRestoreURLForIdentifier(@"livecontainer", music.identifier);
    assert([[library workspaceWithIdentifier:nil].identifier isEqualToString:music.identifier]);
    assert([library renameWorkspace:originalID name:@"Games"]);
    assert([[library workspaceWithIdentifier:nil].identifier isEqualToString:music.identifier]);
    assert([[library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(link, @"livecontainer")].name isEqualToString:@"Games"]);

    LCWindowWorkspace *updated = snapshot(@"C", NO);
    LCNamedWorkspace *games = [library saveWorkspace:updated name:@"Games" replacingIdentifier:originalID];
    assert([games.identifier isEqualToString:originalID]);
    assert(library.workspaces.count == 2);
    assert([[library workspaceWithIdentifier:nil].identifier isEqualToString:originalID]);
    assert([[library workspaceWithIdentifier:music.identifier].snapshot.windows.firstObject.dataUUID isEqualToString:@"B"]);
    assert([[library workspaceWithIdentifier:originalID.uppercaseString].identifier isEqualToString:originalID]);

    // Serialize the collection and reopen it, keeping names, order, geometry and stable links.
    NSError *error = nil;
    id stored = [defaults objectForKey:@"LCWorkspaceLibrary"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:stored format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    assert(data && !error);
    id decoded = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
    [defaults setObject:decoded forKey:@"LCWorkspaceLibrary"];
    library = openLibrary(defaults);
    assert(library.workspaces.count == 2);
    assert([[library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(link, @"livecontainer")].snapshot.propertyList isEqual:updated.propertyList]);
    assert([[library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(musicLink, @"livecontainer")].snapshot.windows.firstObject.dataUUID isEqualToString:@"B"]);
    assert([[library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(musicLink, @"livecontainer")].snapshot.propertyList isEqual:musicSnapshot.propertyList]);

    assert([library removeWorkspace:originalID]);
    assert([library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(link, @"livecontainer")] == nil);
    assert([[library workspaceWithIdentifier:nil].identifier isEqualToString:music.identifier]);
    LCNamedWorkspace *replacement = [library saveWorkspace:original name:@"Games" replacingIdentifier:nil];
    assert(replacement && ![replacement.identifier isEqualToString:originalID]);
    assert([library workspaceWithIdentifier:originalID] == nil); // Never fall back to a name or the latest save.
    assert([library removeWorkspace:replacement.identifier]);
    assert([library removeWorkspace:music.identifier]);
    library = openLibrary(defaults);
    assert(library && library.workspaces.count == 0 && [library workspaceWithIdentifier:nil] == nil);
    assert([[defaults objectForKey:@"LCWindowWorkspace"] isEqual:legacy]);
    assert([[defaults stringForKey:@"unrelated"] isEqualToString:@"keep"]);
}

static void testSavedLayoutEditing(NSUserDefaults *defaults) {
    LCWorkspaceLibrary *library = openLibrary(defaults);
    NSArray *windows = @[
        [[LCWorkspaceWindow alloc] initWithBundleName:@"Game.app" dataUUID:@"A" scale:1.25],
        [[LCWorkspaceWindow alloc] initWithBundleName:@"Music.app" dataUUID:@"B" scale:0.75]
    ];
    NSDictionary *proportions = @{@"2:2:1:1": @{@"rows": @[@0.4], @"columns": @[], @"lastRowColumns": @[]}};
    LCWindowWorkspace *original = [[LCWindowWorkspace alloc] initWithWindows:windows proportions:proportions
        singleRowInLandscape:NO reservePortraitTop:YES reservePortraitBottom:NO];
    LCNamedWorkspace *entry = [library saveWorkspace:original name:@"Editable" replacingIdentifier:nil];
    LCNamedWorkspace *other = [library saveWorkspace:snapshot(@"Z", YES) name:@"Other" replacingIdentifier:nil];
    NSURL *link = LCWorkspaceRestoreURLForIdentifier(@"livecontainer", entry.identifier);
    NSArray *order = [library.workspaces valueForKey:@"identifier"];
    [defaults setBool:YES forKey:@"LCGridReservePortraitTop"];
    [defaults setBool:NO forKey:@"LCGridReservePortraitBottom"];
    [defaults setBool:NO forKey:@"LCGridSingleRowInLandscape"];

    LCWorkspaceLibrary *staleReader = openLibrary(defaults);
    assert([library setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitBottom enabled:YES forWorkspace:entry.identifier]);
    assert([library renameWorkspace:entry.identifier name:@"Renamed"]);
    assert([staleReader setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:NO forWorkspace:entry.identifier]);
    assert([staleReader setLayoutPreference:LCWorkspaceLayoutPreferenceSingleRowInLandscape enabled:YES forWorkspace:entry.identifier]);
    library = openLibrary(defaults);
    LCNamedWorkspace *edited = [library workspaceWithIdentifier:LCWorkspaceRestoreIdentifier(link, @"livecontainer")];
    assert([edited.name isEqualToString:@"Renamed"]);
    assert(edited.snapshot.singleRowInLandscape && !edited.snapshot.reservePortraitTop && edited.snapshot.reservePortraitBottom);
    assert([[library.workspaces valueForKey:@"identifier"] isEqual:order]);
    assert([[library workspaceWithIdentifier:nil].identifier isEqualToString:other.identifier]);
    assert([[library workspaceWithIdentifier:other.identifier].snapshot.propertyList isEqual:other.snapshot.propertyList]);
    assert([edited.snapshot.proportions isEqual:original.proportions]);
    assert([[edited.snapshot.windows valueForKey:@"propertyList"] isEqual:[original.windows valueForKey:@"propertyList"]]);
    // Editing a saved layout must never apply it to the live windows.
    assert([defaults boolForKey:@"LCGridReservePortraitTop"]);
    assert(![defaults boolForKey:@"LCGridReservePortraitBottom"]);
    assert(![defaults boolForKey:@"LCGridSingleRowInLandscape"]);

    // A repeated toggle is harmless; invalid requests must leave every record unchanged.
    id before = [defaults objectForKey:@"LCWorkspaceLibrary"];
    assert([library setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:NO forWorkspace:entry.identifier]);
    assert(![library setLayoutPreference:(LCWorkspaceLayoutPreference)999 enabled:YES forWorkspace:entry.identifier]);
    assert(![library setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:YES forWorkspace:@"bad-id"]);
    assert(![library setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:YES forWorkspace:NSUUID.UUID.UUIDString]);
    assert([[defaults objectForKey:@"LCWorkspaceLibrary"] isEqual:before]);

    // Patching from an older reader keeps a subsequent replacement's apps and other preferences.
    LCWindowWorkspace *replacement = snapshot(@"NewContainer", NO);
    assert([library saveWorkspace:replacement name:@"Renamed" replacingIdentifier:entry.identifier]);
    assert([staleReader setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitBottom enabled:YES forWorkspace:entry.identifier]);
    edited = [staleReader workspaceWithIdentifier:entry.identifier];
    assert(!edited.snapshot.singleRowInLandscape && edited.snapshot.reservePortraitTop && edited.snapshot.reservePortraitBottom);
    assert([[edited.snapshot.windows valueForKey:@"propertyList"] isEqual:[replacement.windows valueForKey:@"propertyList"]]);
    assert([edited.snapshot.proportions isEqual:replacement.proportions]);

    // A copy starts from the saved snapshot, gets its own link and remains independently editable.
    LCNamedWorkspace *copy = [library saveWorkspace:edited.snapshot name:@"Copy" replacingIdentifier:nil];
    assert(copy && ![copy.identifier isEqualToString:entry.identifier]);
    assert([copy.snapshot.propertyList isEqual:edited.snapshot.propertyList]);
    assert([library setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:NO forWorkspace:copy.identifier]);
    assert([library workspaceWithIdentifier:entry.identifier].snapshot.reservePortraitTop);
    assert(![library workspaceWithIdentifier:copy.identifier].snapshot.reservePortraitTop);
    assert([library removeWorkspace:entry.identifier]);
    before = [defaults objectForKey:@"LCWorkspaceLibrary"];
    assert(![staleReader setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:NO forWorkspace:entry.identifier]);
    assert([[defaults objectForKey:@"LCWorkspaceLibrary"] isEqual:before]);
    assert([library removeWorkspace:copy.identifier]);
    assert([library removeWorkspace:other.identifier]);
}

static void testValidationAndFailedEdits(NSUserDefaults *defaults) {
    LCWorkspaceLibrary *library = openLibrary(defaults);
    LCNamedWorkspace *work = [library saveWorkspace:snapshot(@"A", NO) name:@"  Work  " replacingIdentifier:nil];
    assert(work && [work.name isEqualToString:@"Work"]);
    LCNamedWorkspace *games = [library saveWorkspace:snapshot(@"B", YES) name:@"Games" replacingIdentifier:nil];
    assert(games);
    id before = [defaults objectForKey:@"LCWorkspaceLibrary"];
    for (NSString *name in @[@"", @"  \n  ", @"a\nb", @"work", [@"x" stringByPaddingToLength:81 withString:@"x" startingAtIndex:0]]) {
        assert(![library canUseName:name excludingIdentifier:nil]);
        assert([library saveWorkspace:snapshot(@"C", NO) name:name replacingIdentifier:nil] == nil);
        assert(![library renameWorkspace:games.identifier name:name]);
    }
    assert([library canUseName:[@"x" stringByPaddingToLength:80 withString:@"x" startingAtIndex:0] excludingIdentifier:nil]);
    NSString *missing = NSUUID.UUID.UUIDString;
    assert([library workspaceWithIdentifier:missing] == nil);
    assert([library workspaceWithIdentifier:@""] == nil);
    assert([library workspaceWithIdentifier:@"not-an-id"] == nil);
    assert([library saveWorkspace:snapshot(@"C", NO) name:@"New" replacingIdentifier:missing] == nil);
    assert(![library renameWorkspace:missing name:@"New"]);
    assert(![library removeWorkspace:missing]);
    assert([[defaults objectForKey:@"LCWorkspaceLibrary"] isEqual:before]);
    assert([library renameWorkspace:work.identifier name:@"WORK"]);
    assert([library renameWorkspace:games.identifier name:@"遊戲 🎮"]);
    assert([[library workspaceWithIdentifier:games.identifier].name isEqualToString:@"遊戲 🎮"]);

    // A second reader's sequential edits must not be lost when an older instance saves.
    LCWorkspaceLibrary *otherReader = openLibrary(defaults);
    LCNamedWorkspace *extra = [otherReader saveWorkspace:snapshot(@"D", YES) name:@"Extra" replacingIdentifier:nil];
    assert(extra);
    assert([library renameWorkspace:work.identifier name:@"Office"]);
    assert([library workspaceWithIdentifier:extra.identifier] != nil);
    assert([otherReader reload]);
    assert([[otherReader workspaceWithIdentifier:work.identifier].name isEqualToString:@"Office"]);
}

static void testUnreadableDataIsPreserved(NSUserDefaults *defaults) {
    LCWorkspaceLibrary *existing = openLibrary(defaults);
    id valid = [defaults objectForKey:@"LCWorkspaceLibrary"];
    NSDictionary *entry = [valid[@"workspaces"] firstObject];
    NSMutableDictionary *badEntry = [entry mutableCopy];
    badEntry[@"snapshot"] = @{@"version": @9};
    NSMutableDictionary *duplicateName = [entry mutableCopy];
    duplicateName[@"id"] = NSUUID.UUID.UUIDString;
    for (id corrupt in @[@"bad", @[], @{}, @{@"version": @2, @"workspaces": @[]},
                         @{@"version": @1, @"workspaces": @"bad"},
                         @{@"version": @1, @"workspaces": @[entry, entry]},
                         @{@"version": @1, @"workspaces": @[entry, duplicateName]},
                         @{@"version": @1, @"workspaces": @[entry, badEntry]}]) {
        [defaults setObject:corrupt forKey:@"LCWorkspaceLibrary"];
        assert(openLibrary(defaults) == nil);
        assert([existing saveWorkspace:snapshot(@"Z", NO) name:@"New" replacingIdentifier:nil] == nil);
        assert(![existing setLayoutPreference:LCWorkspaceLayoutPreferenceReservePortraitTop enabled:NO forWorkspace:entry[@"id"]]);
        assert([[defaults objectForKey:@"LCWorkspaceLibrary"] isEqual:corrupt]);
    }
    [defaults removeObjectForKey:@"LCWorkspaceLibrary"];
    [defaults setObject:@"bad" forKey:@"LCWindowWorkspace"];
    assert(openLibrary(defaults) == nil);
    assert([defaults objectForKey:@"LCWorkspaceLibrary"] == nil);
    assert([[defaults objectForKey:@"LCWindowWorkspace"] isEqual:@"bad"]);
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"LCWorkspaceLibraryTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        testMigrationAndNamedLinks(defaults);
        testSavedLayoutEditing(defaults);
        testValidationAndFailedEdits(defaults);
        testUnreadableDataIsPreserved(defaults);
        [defaults removePersistentDomainForName:suite];
        puts("Workspace library tests passed (migration, saved layout edits, independent copies, stable links, rename/update/delete, stale readers and invalid data preservation).");
    }
    return 0;
}
