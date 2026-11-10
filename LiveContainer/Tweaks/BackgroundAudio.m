#import "BackgroundAudio.h"
@import AVFAudio;
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef BOOL (*LCBackgroundAudioQueryIMP)(id, SEL);
static LCBackgroundAudioQueryIMP originalOtherAudioPlaying;
static char *backgroundGuestExecutablePath;
static char *backgroundGuestResolvedPath;
static _Atomic(uintptr_t) backgroundGuestImage;

static BOOL LCBackgroundAudioPlaybackCategory(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryAmbient] ||
        [category isEqualToString:AVAudioSessionCategorySoloAmbient] ||
        [category isEqualToString:AVAudioSessionCategoryPlayback];
}

static void LCBackgroundAudioImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    Dl_info image;
    if (!backgroundGuestExecutablePath || atomic_load_explicit(&backgroundGuestImage, memory_order_acquire) ||
        !dladdr(header, &image) || !image.dli_fname || image.dli_fbase != header) return;
    BOOL matches = !strcmp(image.dli_fname, backgroundGuestExecutablePath);
    if (!matches && backgroundGuestResolvedPath) {
        char *resolved = realpath(image.dli_fname, NULL);
        matches = resolved && !strcmp(resolved, backgroundGuestResolvedPath);
        free(resolved);
    }
    if (matches) {
        // Register before dyld's existing path hiding, and identify the image
        // before its initializers. Later queries compare addresses, not paths.
        atomic_store_explicit(&backgroundGuestImage, (uintptr_t)header, memory_order_release);
        NSLog(@"[LC Audio] Background music guest executable identified");
    }
}

static BOOL LCBackgroundAudioOtherAudioPlaying(id session, SEL selector) {
    BOOL playing = originalOtherAudioPlaying(session, selector);
    if (!playing) return playing;
    uintptr_t guestImage = atomic_load_explicit(&backgroundGuestImage, memory_order_acquire);
    if (!guestImage) return playing;
    void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info image;
    if (!dladdr(caller, &image) || (uintptr_t)image.dli_fbase != guestImage) return playing;
    if (!LCBackgroundAudioPlaybackCategory([session category])) return playing;

    // Only direct queries from this guest executable ignore other playback.
    // System and separately loaded SDK/framework callers retain the real value.
    // Statically linked SDK code shares the executable and cannot be separated
    // by image identity. Real interruption notifications are untouched.
    static dispatch_once_t firstIgnoredQuery;
    dispatch_once(&firstIgnoredQuery, ^{
        NSLog(@"[LC Audio] Background music compatibility ignored an other-audio check");
    });
    return NO;
}

static BOOL LCBackgroundAudioHookClass(Class cls) {
    SEL selector = @selector(isOtherAudioPlaying);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    originalOtherAudioPlaying = (LCBackgroundAudioQueryIMP)method_getImplementation(method);
    class_replaceMethod(cls, selector, (IMP)LCBackgroundAudioOtherAudioPlaying, method_getTypeEncoding(method));
    return YES;
}

BOOL LCBackgroundAudioShouldEnable(BOOL liveProcess, NSString *guestAppId,
                                  NSDictionary *appInfo, NSDictionary *launchInfo) {
    return liveProcess && guestAppId.length && [appInfo[@"LCKeepBackgroundAudio"] isEqual:@YES] &&
        ![appInfo[@"dontInjectTweakLoader"] boolValue] && [launchInfo[@"virtualWindow"] isEqual:@YES];
}

void LCBackgroundAudioInstall(NSString *guestExecutablePath) {
    if (!guestExecutablePath.isAbsolutePath) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = guestExecutablePath.fileSystemRepresentation;
        if (!path) return;
        backgroundGuestExecutablePath = strdup(path);
        if (!backgroundGuestExecutablePath) return;
        backgroundGuestResolvedPath = realpath(path, NULL);
        if (!LCBackgroundAudioHookClass(AVAudioSession.class)) {
            free(backgroundGuestExecutablePath);
            backgroundGuestExecutablePath = NULL;
            free(backgroundGuestResolvedPath);
            backgroundGuestResolvedPath = NULL;
            return;
        }
        _dyld_register_func_for_add_image(LCBackgroundAudioImageAdded);
        NSLog(@"[LC Audio] Background music compatibility installed");
    });
}
