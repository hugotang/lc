#import "../LiveContainer/Tweaks/LCSymbolCache.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        uint8_t uuid[16] = {1, 2, 3, 4};
        NSData *image = [NSData dataWithBytes:uuid length:16];
        NSDictionary *valid = @{@"uuid": image, @"offset": @4096};
        assert([LCCachedSymbolOffset(valid, uuid) isEqual:@4096]);
        assert(LCCachedSymbolOffset(valid, NULL) == nil);
        uint8_t updatedUUID[16] = {1, 2, 3, 5};
        assert(LCCachedSymbolOffset(valid, updatedUUID) == nil);
        NSArray *invalidEntries = @[@"bad", @[], NSNull.null, @{}, @{@"uuid": image}, @{@"offset": @4096}];
        for (id entry in invalidEntries) assert(LCCachedSymbolOffset(entry, uuid) == nil);
        for (id value in @[@0, @-1, @(UINT64_MAX), @(NAN), @(INFINITY), @1.5, @YES, @"4096", NSNull.null]) {
            assert(LCCachedSymbolOffset(@{@"uuid": image, @"offset": value}, uuid) == nil);
        }
        for (id value in @[[NSData data], [NSMutableData dataWithLength:15], [NSMutableData dataWithLength:17], @"uuid", @[]]) {
            assert(LCCachedSymbolOffset(@{@"uuid": value, @"offset": @4096}, uuid) == nil);
        }
        assert(!LCSymbolOffsetIsValid(0));
        assert(!LCSymbolOffsetIsValid((uint64_t)0 - (uint64_t)0x180000000));
        assert(!LCSymbolOffsetIsValid(UINT64_MAX));
        assert(LCSymbolOffsetIsValid(1));
        assert(LCSymbolOffsetIsValid(INTPTR_MAX));
        puts("Symbol cache tests passed (failed lookups, malformed values and changed system images).");
    }
    return 0;
}
