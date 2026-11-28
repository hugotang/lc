#import "../LiveContainerSwiftUI/Models/LCGuestExtensionSigning.h"
#include <assert.h>
#include <stdio.h>

static NSMutableDictionary *reloadMetadata(NSDictionary *info) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    assert(data && !error);
    NSMutableDictionary *restored = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:&error];
    assert(restored && !error);
    return restored;
}

static void testUpgradeAndInterruptedSigning(void) {
    // A pre-fix install can have a valid main executable and patched, unsigned
    // helpers without a pending flag. Its first helper launch must still sign.
    NSMutableDictionary *info = [@{@"LCPatchRevision": @7, @"LCGuestExtensionPatchRevision": @1} mutableCopy];
    assert(LCGuestExtensionSigningRequired(info, YES, YES));
    assert(!LCGuestExtensionSigningRequired(info, NO, YES));
    assert(!LCGuestExtensionSigningRequired(info, YES, NO));
    info = reloadMetadata(info); // Interruption before the signer calls back.
    assert(LCGuestExtensionSigningRequired(info, YES, YES));

    // Signing a valid main executable alone is not bundle success.
    LCGuestExtensionSigningDidComplete(info, NO, YES);
    info = reloadMetadata(info);
    assert(LCGuestExtensionSigningRequired(info, YES, YES));
    LCGuestExtensionSigningDidComplete(info, YES, NO);
    info = reloadMetadata(info);
    assert(LCGuestExtensionSigningRequired(info, YES, YES));

    LCGuestExtensionSigningDidComplete(info, YES, YES);
    info = reloadMetadata(info);
    assert([info[@"LCGuestExtensionSignRevision"] integerValue] == 1);
    assert(!LCGuestExtensionSigningRequired(info, YES, YES));
    assert(!LCGuestExtensionSigningRequired(info, NO, YES));
}

static void testPendingSigningAndOptOut(void) {
    NSMutableDictionary *info = [@{@"LCGuestExtensionPatchRevision": @1, @"LCGuestExtensionSignPending": @YES} mutableCopy];
    NSDictionary *before = [info copy];
    // No certificate (JIT), dontSign, and 32-bit launches all prohibit signing.
    assert(!LCGuestExtensionSigningRequired(info, YES, NO));
    assert([info isEqualToDictionary:before]);
    info = reloadMetadata(info);
    assert(LCGuestExtensionSigningRequired(info, YES, YES));
    // An explicitly pending signature survives disabling helper support.
    assert(LCGuestExtensionSigningRequired(info, NO, YES));
    LCGuestExtensionSigningDidComplete(info, NO, NO);
    assert([info[@"LCGuestExtensionSignPending"] boolValue]);
    LCGuestExtensionSigningDidComplete(info, YES, YES);
    info = reloadMetadata(info);
    assert(!info[@"LCGuestExtensionSignPending"]);
    assert(!LCGuestExtensionSigningRequired(info, YES, YES));

    // A later helper patch must be signed even after an earlier success.
    info[@"LCGuestExtensionPatchRevision"] = @2;
    assert(LCGuestExtensionSigningRequired(info, YES, YES));
    LCGuestExtensionSigningDidComplete(info, YES, YES);
    assert([info[@"LCGuestExtensionSignRevision"] integerValue] == 2);
    assert(!LCGuestExtensionSigningRequired(reloadMetadata(info), YES, YES));
}

static void testUnpreparedBundle(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    assert(!LCGuestExtensionSigningRequired(info, YES, YES));
    LCGuestExtensionSigningDidComplete(info, YES, YES);
    assert(!info[@"LCGuestExtensionSignRevision"]);
    info[@"LCGuestExtensionPatchRevision"] = @1;
    assert(LCGuestExtensionSigningRequired(info, YES, YES));
}

int main(void) {
    @autoreleasepool {
        testUpgradeAndInterruptedSigning();
        testPendingSigningAndOptOut();
        testUnpreparedBundle();
    }
    puts("Guest extension signing migration and retry tests passed");
    return 0;
}
