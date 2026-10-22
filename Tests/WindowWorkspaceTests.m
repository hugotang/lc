#import "../MultitaskSupport/WindowWorkspace.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static NSDictionary *window(NSString *container) {
    return @{@"bundleName": @"Notes.app", @"dataUUID": container, @"scale": @1.25};
}
static LCWindowWorkspace *decode(NSArray *windows, NSDictionary *proportions) {
    return [[LCWindowWorkspace alloc] initWithPropertyList:@{@"version": @1, @"windows": windows, @"proportions": proportions}];
}

static void testLandscapePreference(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSString *container in @[@"A", @"B", @"C", @"D"]) {
        [windows addObject:[[LCWorkspaceWindow alloc] initWithBundleName:@"Game.app" dataUUID:container scale:1.25]];
    }
    NSDictionary *portrait = @{@"rows": @[@0.4], @"columns": @[@0.6], @"lastRowColumns": @[@0.6]};
    NSDictionary *landscape = @{@"rows": @[@0.5], @"columns": @[@0.7], @"lastRowColumns": @[@0.7]};
    NSDictionary *singleRow = @{@"rows": @[], @"columns": @[@0.2, @0.5, @0.8], @"lastRowColumns": @[@0.2, @0.5, @0.8]};
    NSDictionary *proportions = @{@"4:2:2:1": portrait, @"4:2:2:0": landscape, @"4:1:4:0": singleRow};
    for (NSNumber *enabled in @[@NO, @YES]) {
        LCWindowWorkspace *workspace = [[LCWindowWorkspace alloc] initWithWindows:windows proportions:proportions
                                                            singleRowInLandscape:enabled.boolValue];
        assert(workspace.singleRowInLandscape == enabled.boolValue);
        assert(workspace.reservePortraitTop && !workspace.reservePortraitBottom);
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:workspace.propertyList format:NSPropertyListBinaryFormat_v1_0
                                                               options:0 error:&error];
        assert(data && !error);
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
        LCWindowWorkspace *restored = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
        assert(restored && restored.singleRowInLandscape == enabled.boolValue);
        assert([restored.propertyList isEqual:workspace.propertyList]);
        assert([restored.proportions isEqual:proportions]);
        for (NSUInteger i = 0; i < 4; ++i) {
            assert([restored.windows[i].dataUUID isEqualToString:[windows[i] dataUUID]]);
            assert(restored.windows[i].scale == 1.25);
        }
    }
    // An absent or malformed optional preference must not break an otherwise usable old save.
    NSMutableDictionary *old = [@{@"version": @1, @"windows": @[window(@"A")], @"proportions": proportions} mutableCopy];
    assert(![[LCWindowWorkspace alloc] initWithPropertyList:old].singleRowInLandscape);
    for (id value in @[NSNull.null, @"true", @2, @-1, @(NAN), @[], @{}]) {
        old[@"singleRowInLandscape"] = value;
        LCWindowWorkspace *restored = [[LCWindowWorkspace alloc] initWithPropertyList:old];
        assert(restored && !restored.singleRowInLandscape);
        assert([restored.proportions isEqual:proportions]);
    }
}

static void testPortraitReservations(void) {
    LCWorkspaceWindow *entry = [[LCWorkspaceWindow alloc] initWithBundleName:@"Game.app" dataUUID:@"A" scale:1.25];
    for (NSNumber *top in @[@NO, @YES]) {
        for (NSNumber *bottom in @[@NO, @YES]) {
            LCWindowWorkspace *workspace = [[LCWindowWorkspace alloc] initWithWindows:@[entry] proportions:@{}
                singleRowInLandscape:YES reservePortraitTop:top.boolValue reservePortraitBottom:bottom.boolValue];
            assert(workspace && workspace.reservePortraitTop == top.boolValue && workspace.reservePortraitBottom == bottom.boolValue);
            NSError *error = nil;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:workspace.propertyList format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0 error:&error];
            assert(data && !error);
            id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
            LCWindowWorkspace *restored = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
            assert(restored && restored.singleRowInLandscape);
            assert(restored.reservePortraitTop == top.boolValue && restored.reservePortraitBottom == bottom.boolValue);
            assert([restored.propertyList isEqual:workspace.propertyList]);
        }
    }
    NSMutableDictionary *old = [@{@"version": @1, @"windows": @[window(@"A")], @"singleRowInLandscape": @YES} mutableCopy];
    LCWindowWorkspace *restored = [[LCWindowWorkspace alloc] initWithPropertyList:old];
    assert(restored && restored.reservePortraitTop && !restored.reservePortraitBottom && restored.singleRowInLandscape);
    for (id invalid in @[NSNull.null, @"false", @"true", @2, @-1, @(NAN), @[], @{}]) {
        // One corrupt preference must not discard the other valid preference or the workspace.
        old[@"reservePortraitTop"] = invalid;
        old[@"reservePortraitBottom"] = @YES;
        restored = [[LCWindowWorkspace alloc] initWithPropertyList:old];
        assert(restored && restored.reservePortraitTop && restored.reservePortraitBottom && restored.singleRowInLandscape);
        old[@"reservePortraitTop"] = @NO;
        old[@"reservePortraitBottom"] = invalid;
        restored = [[LCWindowWorkspace alloc] initWithPropertyList:old];
        assert(restored && !restored.reservePortraitTop && !restored.reservePortraitBottom && restored.singleRowInLandscape);
    }
}

static void testTapSyncGroup(void) {
    NSMutableDictionary *plist = [decode(@[window(@"A"), window(@"B"), window(@"C")], @{}).propertyList mutableCopy];
    NSDictionary *group = @{@"source": @"B", @"targets": @[@"C", @"A"]};
    plist[@"tapSync"] = group;
    LCWindowWorkspace *snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
    assert([snapshot.tapSyncGroup isEqual:group]);
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot.propertyList
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    LCWindowWorkspace *copy = [[LCWindowWorkspace alloc] initWithPropertyList:
        [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil]];
    assert([copy.tapSyncGroup isEqual:group]);
    NSMutableDictionary *gestureGroup = group.mutableCopy;
    gestureGroup[@"mode"] = @"singleFinger";
    gestureGroup[@"active"] = @YES;
    gestureGroup[@"contact"] = @123;
    gestureGroup[@"queue"] = @[@1];
    plist[@"tapSync"] = gestureGroup;
    snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
    assert([snapshot.tapSyncGroup[@"mode"] isEqual:@"singleFinger"] && snapshot.tapSyncGroup.count == 3);
    gestureGroup[@"mode"] = @"twoFingers";
    plist[@"tapSync"] = gestureGroup;
    snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
    assert([snapshot.tapSyncGroup[@"mode"] isEqual:@"twoFingers"] && snapshot.tapSyncGroup.count == 3);
    NSData *multiData = [NSPropertyListSerialization dataWithPropertyList:snapshot.propertyList
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    LCWindowWorkspace *multiCopy = [[LCWindowWorkspace alloc] initWithPropertyList:
        [NSPropertyListSerialization propertyListWithData:multiData options:0 format:NULL error:nil]];
    assert([multiCopy.tapSyncGroup isEqual:snapshot.tapSyncGroup]);
    copy = [[LCWindowWorkspace alloc] initWithPropertyList:snapshot.propertyList];
    assert([copy.tapSyncGroup isEqual:snapshot.tapSyncGroup]);
    for (id mode in @[@"tapsOnly", @"unknown-mode", @1, NSNull.null, @[]]) {
        gestureGroup[@"mode"] = mode;
        plist[@"tapSync"] = gestureGroup;
        snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
        assert([snapshot.tapSyncGroup isEqual:group]);
    }
    // Active state and pending input must never be restored, even if inserted into a property list.
    plist[@"tapSync"] = @{@"source": @"B", @"targets": @[@"C", @"A"], @"active": @YES, @"queue": @[@1]};
    snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
    assert([snapshot.tapSyncGroup isEqual:group] && snapshot.propertyList[@"tapSync"][@"active"] == nil);
    for (id invalid in @[@"bad", @{}, @{@"source": @"D", @"targets": @[@"A"]},
                          @{@"source": @"A", @"targets": @[@"A"]}, @{@"source": @"A", @"targets": @[@"B", @"B"]},
                          @{@"source": @"A", @"targets": @[@"D"]}, @{@"source": @"A", @"targets": @[]},
                          @{@"source": @"A", @"targets": @[@1]}]) {
        plist[@"tapSync"] = invalid;
        snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
        assert(snapshot && snapshot.windows.count == 3 && snapshot.tapSyncGroup.count == 0);
    }
    plist[@"windows"] = @[window(@"A"), @{@"bundleName": @"Other.app", @"dataUUID": @"B", @"scale": @1}];
    plist[@"tapSync"] = @{@"source": @"A", @"targets": @[@"B"]};
    assert([[LCWindowWorkspace alloc] initWithPropertyList:plist].tapSyncGroup.count == 0);
    assert(decode(@[window(@"A")], @{}).tapSyncGroup.count == 0);
}

int main(void) {
    @autoreleasepool {
        testLandscapePreference();
        testPortraitReservations();
        testTapSyncGroup();
        NSDictionary *validGrid = @{@"rows": @[@0.4], @"columns": @[@0.65], @"lastRowColumns": @[]};
        LCWindowWorkspace *workspace = decode(@[window(@"A"), window(@"B")], @{@"3:2:2:1": validGrid});
        assert(workspace.windows.count == 2);
        assert([workspace.windows[0].dataUUID isEqualToString:@"A"]);
        assert(workspace.windows[1].scale == 1.25);
        assert([workspace.proportions[@"3:2:2:1"] isEqual:validGrid]);
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:workspace.propertyList format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        assert(data && !error);
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
        LCWindowWorkspace *restored = [[LCWindowWorkspace alloc] initWithPropertyList:plist];
        assert([restored.propertyList isEqual:workspace.propertyList]);

        assert(decode(@[], @{}) == nil);
        assert(decode(@[window(@"A"), window(@"A")], @{}) == nil);
        NSMutableArray *tooMany = [NSMutableArray array];
        for (NSUInteger i = 0; i < 65; ++i) [tooMany addObject:window(@(i).stringValue)];
        assert(decode(tooMany, @{}) == nil);
        for (id corrupt in @[NSNull.null, @[], @"bad", @{}, @{@"version": @2, @"windows": @[window(@"A")]}]) {
            assert([[LCWindowWorkspace alloc] initWithPropertyList:corrupt] == nil);
        }
        for (id scale in @[@0.49, @2.01, @(NAN), @(INFINITY), @"1", NSNull.null]) {
            NSMutableDictionary *entry = [window(@"A") mutableCopy];
            entry[@"scale"] = scale;
            assert(decode(@[entry], @{}) == nil);
        }
        for (NSString *name in @[@"", @"../A", @"/A", @"A/B", @"A\\B"]) {
            assert(decode(@[window(name)], @{}) == nil);
        }
        NSMutableDictionary *entry = [window(@"A") mutableCopy];
        entry[@"bundleName"] = @"../../Notes.app";
        assert(decode(@[entry], @{}) == nil);
        entry[@"bundleName"] = NSNull.null;
        assert(decode(@[entry], @{}) == nil);
        for (double scale = 0.5; scale <= 2; scale += 0.5) {
            assert([[LCWorkspaceWindow alloc] initWithBundleName:@"Notes.app" dataUUID:@"A" scale:scale]);
        }

        for (NSString *key in @[@"3:2:2:2", @"3:1:1:0", @"0:0:0:0", @"3:3:2:0", @"99999999999999999999:2:2:1", @"bad"]) {
            assert(decode(@[window(@"A")], @{key: validGrid}).proportions.count == 0);
        }
        for (id rows in @[@[], @[@0.2, @0.6], @[@0], @[@1], @[@-1], @[@(NAN)], @[@"0.4"], NSNull.null]) {
            NSMutableDictionary *grid = [validGrid mutableCopy];
            grid[@"rows"] = rows;
            assert(decode(@[window(@"A")], @{@"3:2:2:1": grid}).proportions.count == 0);
        }
        // Corrupt proportions do not prevent launching an otherwise valid workspace.
        assert(decode(@[window(@"A")], @{ @"3:2:2:1": @"bad" }).windows.count == 1);
        NSMutableDictionary *mutableEntry = [window(@"A") mutableCopy];
        LCWindowWorkspace *immutable = decode(@[mutableEntry], @{@"3:2:2:1": validGrid});
        mutableEntry[@"dataUUID"] = @"Changed";
        assert([immutable.windows[0].dataUUID isEqualToString:@"A"]);
        puts("Workspace tests passed (landscape and portrait preferences, old saves, property-list round trip, multiple containers, invalid snapshots and divider validation).");
    }
    return 0;
}
