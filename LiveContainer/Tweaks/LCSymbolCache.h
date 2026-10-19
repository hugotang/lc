#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>

// Failed lookups used to store NULL - imageBase, which wraps to a huge unsigned offset.
static inline BOOL LCSymbolOffsetIsValid(uint64_t offset) {
    return offset > 0 && offset <= INTPTR_MAX;
}

static inline NSNumber *LCCachedSymbolOffset(id entry, const uint8_t *imageUUID) {
    if (![entry isKindOfClass:NSDictionary.class] || !imageUUID) return nil;
    id uuid = entry[@"uuid"];
    id offset = entry[@"offset"];
    if (![uuid isKindOfClass:NSData.class] || [uuid length] != 16 ||
        memcmp(imageUUID, [uuid bytes], 16) != 0 ||
        ![offset isKindOfClass:NSNumber.class]) return nil;
    // Offsets are integer addresses, never floating-point or boolean preference values.
    if (CFGetTypeID((__bridge CFTypeRef)offset) == CFBooleanGetTypeID() ||
        strchr("fd", [offset objCType][0]) || !LCSymbolOffsetIsValid([offset unsignedLongLongValue])) return nil;
    return offset;
}
