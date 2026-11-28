#import <Foundation/Foundation.h>

// Patch completion alone did not guarantee signing in older releases. A
// separate revision records which prepared helpers completed bundle signing.
static inline BOOL LCGuestExtensionSigningRequired(NSDictionary *info, BOOL helpersEnabled, BOOL signingAllowed) {
    if (!signingAllowed) return NO;
    NSInteger patchRevision = [info[@"LCGuestExtensionPatchRevision"] integerValue];
    NSInteger signRevision = [info[@"LCGuestExtensionSignRevision"] integerValue];
    return [info[@"LCGuestExtensionSignPending"] boolValue] || (helpersEnabled && patchRevision > signRevision);
}

static inline void LCGuestExtensionSigningDidComplete(NSMutableDictionary *info, BOOL success, BOOL signatureValid) {
    if (!success || !signatureValid) return;
    NSInteger patchRevision = [info[@"LCGuestExtensionPatchRevision"] integerValue];
    if (patchRevision > 0) info[@"LCGuestExtensionSignRevision"] = @(patchRevision);
    [info removeObjectForKey:@"LCGuestExtensionSignPending"];
}
