#import "AmbientAudio.h"
@import AVFAudio;
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <string.h>

#ifndef LC_AMBIENT_AUDIO_TESTING
#include "../../litehook/src/litehook.h"
#endif

// Keep input/voice/multiroute categories intact. Ambient already mixes and
// honours the device's silent switch; routing, ducking and playback-only modes
// are deliberately omitted when an output category is converted.
static BOOL LCAmbientPlaybackCategory(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryAmbient] ||
        [category isEqualToString:AVAudioSessionCategorySoloAmbient] ||
        [category isEqualToString:AVAudioSessionCategoryPlayback];
}

typedef BOOL (*LCAmbientCategoryIMP)(id, SEL, NSString *, NSError **);
typedef BOOL (*LCAmbientOptionsIMP)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*LCAmbientModeOptionsIMP)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*LCAmbientPolicyIMP)(id, SEL, NSString *, NSString *, AVAudioSessionRouteSharingPolicy,
                                AVAudioSessionCategoryOptions, NSError **);
static LCAmbientCategoryIMP originalCategory, originalMode;
static LCAmbientOptionsIMP originalOptions;
static LCAmbientModeOptionsIMP originalModeOptions;
static LCAmbientPolicyIMP originalPolicy;
static _Thread_local unsigned int ambientSetterDepth;

static BOOL LCAmbientSetPlayback(id session, NSError **error) {
    // Use the original complete setter once, including on error. This also
    // supplies a compatible default mode instead of retaining MoviePlayback.
    ambientSetterDepth++;
    @try {
        return originalPolicy(session, @selector(setCategory:mode:routeSharingPolicy:options:error:),
            AVAudioSessionCategoryAmbient, AVAudioSessionModeDefault, AVAudioSessionRouteSharingPolicyDefault, 0, error);
    } @finally { ambientSetterDepth--; }
}

static BOOL LCAmbientSetCategory(id session, SEL selector, NSString *category, NSError **error) {
    if (ambientSetterDepth) return originalCategory(session, selector, category, error);
    if (LCAmbientPlaybackCategory(category)) return LCAmbientSetPlayback(session, error);
    ambientSetterDepth++;
    @try { return originalCategory(session, selector, category, error); }
    @finally { ambientSetterDepth--; }
}
static BOOL LCAmbientSetOptions(id session, SEL selector, NSString *category,
                               AVAudioSessionCategoryOptions options, NSError **error) {
    if (ambientSetterDepth) return originalOptions(session, selector, category, options, error);
    if (LCAmbientPlaybackCategory(category)) return LCAmbientSetPlayback(session, error);
    ambientSetterDepth++;
    @try { return originalOptions(session, selector, category, options, error); }
    @finally { ambientSetterDepth--; }
}
static BOOL LCAmbientSetModeOptions(id session, SEL selector, NSString *category, NSString *mode,
                                   AVAudioSessionCategoryOptions options, NSError **error) {
    if (ambientSetterDepth) return originalModeOptions(session, selector, category, mode, options, error);
    if (LCAmbientPlaybackCategory(category)) return LCAmbientSetPlayback(session, error);
    ambientSetterDepth++;
    @try { return originalModeOptions(session, selector, category, mode, options, error); }
    @finally { ambientSetterDepth--; }
}
static BOOL LCAmbientSetPolicy(id session, SEL selector, NSString *category, NSString *mode,
                             AVAudioSessionRouteSharingPolicy policy,
                             AVAudioSessionCategoryOptions options, NSError **error) {
    if (ambientSetterDepth) return originalPolicy(session, selector, category, mode, policy, options, error);
    if (LCAmbientPlaybackCategory(category)) return LCAmbientSetPlayback(session, error);
    ambientSetterDepth++;
    @try { return originalPolicy(session, selector, category, mode, policy, options, error); }
    @finally { ambientSetterDepth--; }
}
static BOOL LCAmbientSetMode(id session, SEL selector, NSString *mode, NSError **error) {
    if (ambientSetterDepth) return originalMode(session, selector, mode, error);
    if (LCAmbientPlaybackCategory([session category])) mode = AVAudioSessionModeDefault;
    ambientSetterDepth++;
    @try { return originalMode(session, selector, mode, error); }
    @finally { ambientSetterDepth--; }
}

static BOOL LCAmbientHookClass(Class cls) {
    SEL selectors[] = {@selector(setCategory:error:), @selector(setCategory:withOptions:error:),
        @selector(setCategory:mode:options:error:), @selector(setCategory:mode:routeSharingPolicy:options:error:),
        @selector(setMode:error:)};
    IMP replacements[] = {(IMP)LCAmbientSetCategory, (IMP)LCAmbientSetOptions, (IMP)LCAmbientSetModeOptions,
        (IMP)LCAmbientSetPolicy, (IMP)LCAmbientSetMode};
    IMP originals[5];
    Method methods[5];
    for (NSUInteger index = 0; index < 5; index++) {
        methods[index] = class_getInstanceMethod(cls, selectors[index]);
        if (!methods[index]) return NO;
        originals[index] = method_getImplementation(methods[index]);
    }
    originalCategory = (LCAmbientCategoryIMP)originals[0];
    originalOptions = (LCAmbientOptionsIMP)originals[1];
    originalModeOptions = (LCAmbientModeOptionsIMP)originals[2];
    originalPolicy = (LCAmbientPolicyIMP)originals[3];
    originalMode = (LCAmbientCategoryIMP)originals[4];
    for (NSUInteger index = 0; index < 5; index++) {
        // Add a local method first in case the implementation is inherited.
        class_replaceMethod(cls, selectors[index], replacements[index], method_getTypeEncoding(methods[index]));
    }
    return YES;
}

// AudioSession.h's legacy playback categories: 'ambi', 'solo', 'medi'.
// Keep the ABI and return status intact; engines can still activate/deactivate
// their own sessions and receive real interruption notifications.
typedef int32_t (*LCAmbientLegacyProperty)(uint32_t, uint32_t, const void *);
static LCAmbientLegacyProperty originalLegacyProperty;
static int32_t LCAmbientSetLegacyProperty(uint32_t property, uint32_t size, const void *data) {
    if (property == 0x61636174 && size == sizeof(uint32_t) && data) { // 'acat'
        uint32_t category;
        memcpy(&category, data, sizeof(category));
        if (category == 0x616d6269 || category == 0x736f6c6f || category == 0x6d656469) {
            const uint32_t ambient = 0x616d6269;
            return originalLegacyProperty(property, size, &ambient);
        }
    }
    return originalLegacyProperty(property, size, data);
}

BOOL LCAmbientAudioShouldEnable(BOOL liveProcess, NSString *guestAppId,
                               NSDictionary *appInfo, NSDictionary *launchInfo) {
    return liveProcess && guestAppId.length && [appInfo[@"LCForceAmbientAudio"] isEqual:@YES] &&
        ![appInfo[@"dontInjectTweakLoader"] boolValue] && [launchInfo[@"virtualWindow"] isEqual:@YES];
}

void LCAmbientAudioInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!LCAmbientHookClass(AVAudioSession.class)) return;
#ifndef LC_AMBIENT_AUDIO_TESTING
        originalLegacyProperty = (LCAmbientLegacyProperty)dlsym(RTLD_DEFAULT, "AudioSessionSetProperty");
        if (!originalLegacyProperty) {
            void *library = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY | RTLD_LOCAL);
            if (library) originalLegacyProperty = (LCAmbientLegacyProperty)dlsym(library, "AudioSessionSetProperty");
        }
        if (originalLegacyProperty) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)originalLegacyProperty,
                                   (void *)LCAmbientSetLegacyProperty, NULL);
        }
#endif
        // Configure playback without activating it. Guest activation and
        // interruption recovery remain the guest's responsibility.
        NSError *error = nil;
        if (!LCAmbientSetPlayback(AVAudioSession.sharedInstance, &error)) {
            NSLog(@"[LC Audio] Ambient compatibility setup failed: %@", error);
        }
    });
}
