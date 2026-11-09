#import <Foundation/Foundation.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

enum { LCTextSyncMaximumLength = 4096 };

static inline BOOL LCTextSyncStringIsValid(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || [value length] > limit) return NO;
    NSString *text = value;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar unit = [text characterAtIndex:i];
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (++i >= text.length) return NO;
            unit = [text characterAtIndex:i];
            if (unit < 0xDC00 || unit > 0xDFFF) return NO;
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) return NO;
    }
    return YES;
}

static inline BOOL LCTextSyncIsScalarBoundary(NSString *text, NSUInteger offset) {
    if (offset > text.length) return NO;
    if (!offset || offset == text.length) return YES;
    unichar unit = [text characterAtIndex:offset];
    return unit < 0xDC00 || unit > 0xDFFF;
}

static inline BOOL LCTextSyncUnsignedValue(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= maximum && floor(number) == number;
}

// Contains no placeholder or user-visible label, which may contain account data.
static inline BOOL LCTextSyncFieldIsValid(id field) {
    if (![field isKindOfClass:NSDictionary.class] || [field count] != 3 ||
        !([field[@"kind"] isEqual:@"field"] || [field[@"kind"] isEqual:@"view"]) ||
        !LCTextSyncStringIsValid(field[@"identifier"], 1024)) return NO;
    NSArray *path = field[@"path"];
    if (![path isKindOfClass:NSArray.class] || path.count > 64) return NO;
    for (id index in path) if (!LCTextSyncUnsignedValue(index, 4095)) return NO;
    return YES;
}

static inline BOOL LCTextSyncPacketIsValid(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 6 ||
        !LCTextSyncStringIsValid(value[@"before"], LCTextSyncMaximumLength) ||
        !LCTextSyncStringIsValid(value[@"after"], LCTextSyncMaximumLength) ||
        [value[@"before"] isEqual:value[@"after"]] || !LCTextSyncFieldIsValid(value[@"field"]) ||
        ![value[@"timestamp"] isKindOfClass:NSNumber.class]) return NO;
    double timestamp = [value[@"timestamp"] doubleValue];
    NSString *after = value[@"after"];
    if (!isfinite(timestamp) || timestamp < 0 ||
        !LCTextSyncUnsignedValue(value[@"selectionLocation"], after.length) ||
        !LCTextSyncUnsignedValue(value[@"selectionLength"], after.length)) return NO;
    NSUInteger location = [value[@"selectionLocation"] unsignedIntegerValue];
    NSUInteger length = [value[@"selectionLength"] unsignedIntegerValue];
    return length <= after.length - location && LCTextSyncIsScalarBoundary(after, location) &&
        LCTextSyncIsScalarBoundary(after, location + length);
}

static inline BOOL LCTextSyncPacketIsFresh(id value, NSTimeInterval now) {
    if (!LCTextSyncPacketIsValid(value) || !isfinite(now) || now < 0) return NO;
    NSTimeInterval age = now - [value[@"timestamp"] doubleValue];
    return age >= 0 && age <= 0.75;
}

NS_ASSUME_NONNULL_END
