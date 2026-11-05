#import "../LiveContainer/LCAppDisplaySettings.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        assert(LCAppInterfaceModeFromInfo(@{}) == LCAppInterfaceModeAutomatic);
        assert(CGSizeEqualToSize(LCAppAspectRatioFromInfo(@{}), CGSizeZero));
        assert(!LCAppDisplayUsesWindowScreenSize(@{}));
        for (id corrupt in @[NSNull.null, @"phone", @(-1), @3, @1.5, @[], @{}]) {
            assert(LCAppInterfaceModeFromInfo(@{LCAppInterfaceModeKey: corrupt}) == LCAppInterfaceModeAutomatic);
        }
        for (id corrupt in @[NSNull.null, @"9:16", @[], @[@9], @[@9, @16, @1], @[@"9", @16],
                             @[@0, @16], @[@(-9), @16], @[@(NAN), @16], @[@9, @(INFINITY)],
                             @[@10001, @10001], @[@1, @10000]]) {
            assert(CGSizeEqualToSize(LCAppAspectRatioFromInfo(@{LCAppWindowAspectRatioKey: corrupt}), CGSizeZero));
        }
        for (NSArray *ratio in @[@[@9, @16], @[@16, @9], @[@3, @4], @[@4, @3], @[@9, @19.5], @[@1, @10]]) {
            for (NSNumber *mode in @[@0, @1, @2]) {
                NSMutableDictionary *app = [@{LCAppInterfaceModeKey: mode, LCAppWindowAspectRatioKey: ratio,
                                              @"LCUseWindowScreenSize": @NO} mutableCopy];
                NSDictionary *snapshot = LCAppDisplaySettingsSnapshot(app);
                NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:snapshot
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
                NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:encoded options:0 format:NULL error:NULL];
                assert([decoded isEqual:snapshot]);
                assert(LCAppInterfaceModeFromInfo(decoded) == mode.integerValue);
                CGSize size = LCAppAspectRatioFromInfo(decoded);
                assert(size.width == [ratio[0] doubleValue] && size.height == [ratio[1] doubleValue]);
                assert(LCAppDisplayUsesWindowScreenSize(decoded));
                // An in-flight launch keeps its captured choices after editing the app.
                [app removeAllObjects];
                NSDictionary *effective = LCAppDisplaySettingsForLaunch(app, @{@"appDisplaySettings": decoded});
                assert([effective isEqual:snapshot]);
                assert(LCAppDisplaySettingsForLaunch(app, nil) == app);
                assert(LCAppDisplaySettingsForLaunch(app, @{@"appDisplaySettings": NSNull.null}) == app);
            }
        }
        assert(LCAppDisplayUsesWindowScreenSize(@{@"LCUseWindowScreenSize": @YES}));
        assert(!LCAppDisplayUsesWindowScreenSize(@{LCAppInterfaceModeKey: @1}));
        puts("App display settings passed (defaults, ratio validation, mode validation, saved values and launch snapshots).");
    }
    return 0;
}
