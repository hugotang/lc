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

int main(void) {
    @autoreleasepool {
        testLandscapePreference();
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
        puts("Workspace tests passed (landscape preference, old saves, property-list round trip, multiple containers, invalid snapshots and divider validation).");
    }
    return 0;
}
