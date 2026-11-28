#import <XCTest/XCTest.h>
#import "../LiveContainer/Tweaks/BackgroundAudio.m"

@interface LCTestBackgroundSessionBase : NSObject
@property(nonatomic, copy) NSString *category;
@property(nonatomic) BOOL otherPlaying, throwOnQuery;
@property(nonatomic) NSUInteger queryCalls;
- (BOOL)isOtherAudioPlaying;
@end
@implementation LCTestBackgroundSessionBase
- (BOOL)isOtherAudioPlaying {
    self.queryCalls++;
    if (self.throwOnQuery) [NSException raise:@"LCTestBackgroundQuery" format:@"Test exception"];
    return self.otherPlaying;
}
@end
@interface LCTestBackgroundSession : LCTestBackgroundSessionBase
@end
@implementation LCTestBackgroundSession
@end

// This query originates in the test bundle, which stands in for the guest's
// executable. NSInvocation supplies a real, separately loaded framework caller.
static BOOL LCTestGuestAudioQuery(LCTestBackgroundSessionBase *session) {
    return [session isOtherAudioPlaying];
}

@interface BackgroundAudioTests : XCTestCase
@end
@implementation BackgroundAudioTests
- (void)setUp {
    [super setUp];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ XCTAssertTrue(LCBackgroundAudioHookClass(LCTestBackgroundSession.class)); });
    Dl_info image;
    XCTAssertTrue(dladdr((void *)LCTestGuestAudioQuery, &image));
    free(backgroundGuestExecutablePath);
    backgroundGuestExecutablePath = strdup(image.dli_fname);
    free(backgroundGuestResolvedPath);
    backgroundGuestResolvedPath = realpath(image.dli_fname, NULL);
    atomic_store(&backgroundGuestImage, 0);
    LCBackgroundAudioImageAdded(image.dli_fbase, 0);
    XCTAssertEqual(atomic_load(&backgroundGuestImage), (uintptr_t)image.dli_fbase);
}
- (void)tearDown {
    atomic_store(&backgroundGuestImage, 0);
    free(backgroundGuestExecutablePath);
    backgroundGuestExecutablePath = NULL;
    free(backgroundGuestResolvedPath);
    backgroundGuestResolvedPath = NULL;
    [super tearDown];
}
- (LCTestBackgroundSession *)session {
    LCTestBackgroundSession *session = [LCTestBackgroundSession new];
    session.category = AVAudioSessionCategoryAmbient;
    session.otherPlaying = YES;
    return session;
}
- (void)testSavedOptInRequiresInjectedVirtualGuest {
    NSDictionary *enabled = @{@"LCKeepBackgroundAudio": @YES};
    NSDictionary *virtual = @{@"virtualWindow": @YES};
    XCTAssertTrue(LCBackgroundAudioShouldEnable(YES, @"game", enabled, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(NO, @"game", enabled, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, nil, enabled, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"", enabled, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game", @{}, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game", @{@"LCKeepBackgroundAudio": @NO}, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game", @{@"LCForceAmbientAudio": @YES}, virtual));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game", enabled, nil));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game", enabled, @{@"virtualWindow": @NO}));
    XCTAssertFalse(LCBackgroundAudioShouldEnable(YES, @"game",
        @{@"LCKeepBackgroundAudio": @YES, @"dontInjectTweakLoader": @YES}, virtual));
}
- (void)testGuestPlaybackIgnoresOtherAudioWithoutChangingCategory {
    for (NSString *category in @[AVAudioSessionCategoryAmbient, AVAudioSessionCategorySoloAmbient, AVAudioSessionCategoryPlayback]) {
        LCTestBackgroundSession *session = self.session;
        session.category = category;
        XCTAssertFalse(LCTestGuestAudioQuery(session));
        XCTAssertEqual(session.queryCalls, 1u);
        XCTAssertEqualObjects(session.category, category);
        session.otherPlaying = NO;
        XCTAssertFalse(LCTestGuestAudioQuery(session));
        XCTAssertEqual(session.queryCalls, 2u);
    }
    // Replacing an inherited method must not alter its parent class.
    LCTestBackgroundSessionBase *parent = [LCTestBackgroundSessionBase new];
    parent.category = AVAudioSessionCategoryAmbient;
    parent.otherPlaying = YES;
    XCTAssertTrue(LCTestGuestAudioQuery(parent));
}
- (void)testRecordingAndUnknownCategoriesRetainRealDetection {
    for (NSString *category in @[AVAudioSessionCategoryRecord, AVAudioSessionCategoryPlayAndRecord,
                                 AVAudioSessionCategoryMultiRoute, @"FutureCategory"]) {
        LCTestBackgroundSession *session = self.session;
        session.category = category;
        XCTAssertTrue(LCTestGuestAudioQuery(session));
        session.otherPlaying = NO;
        XCTAssertFalse(LCTestGuestAudioQuery(session));
        XCTAssertEqualObjects(session.category, category);
        XCTAssertEqual(session.queryCalls, 2u);
    }
    LCTestBackgroundSession *session = self.session;
    session.category = nil;
    XCTAssertTrue(LCTestGuestAudioQuery(session));
}
- (void)testFrameworkInvocationRetainsRealDetection {
    LCTestBackgroundSession *session = self.session;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:
        [session methodSignatureForSelector:@selector(isOtherAudioPlaying)]];
    invocation.target = session;
    invocation.selector = @selector(isOtherAudioPlaying);
    [invocation invoke];
    BOOL result = NO;
    [invocation getReturnValue:&result];
    XCTAssertTrue(result);
    XCTAssertEqual(session.queryCalls, 1u);
    XCTAssertFalse(LCTestGuestAudioQuery(session));
    session.otherPlaying = NO;
    [invocation invoke];
    [invocation getReturnValue:&result];
    XCTAssertFalse(result);
    XCTAssertEqual(session.queryCalls, 3u);
}
- (void)testUnknownAndUnrelatedImagesCannotSuppressAudioDetection {
    LCTestBackgroundSession *session = self.session;
    atomic_store(&backgroundGuestImage, 0);
    XCTAssertTrue(LCTestGuestAudioQuery(session));
    Dl_info guest, unrelated;
    XCTAssertTrue(dladdr((void *)LCTestGuestAudioQuery, &guest));
    XCTAssertTrue(dladdr((void *)objc_getClass, &unrelated));
    XCTAssertNotEqual(guest.dli_fbase, unrelated.dli_fbase);
    LCBackgroundAudioImageAdded(unrelated.dli_fbase, 0);
    XCTAssertEqual(atomic_load(&backgroundGuestImage), 0u);
    XCTAssertTrue(LCTestGuestAudioQuery(session));
    LCBackgroundAudioImageAdded(guest.dli_fbase, 0);
    XCTAssertFalse(LCTestGuestAudioQuery(session));
    LCBackgroundAudioImageAdded(unrelated.dli_fbase, 0);
    XCTAssertEqual(atomic_load(&backgroundGuestImage), (uintptr_t)guest.dli_fbase);
    // Equivalent bundle paths must survive /var versus /private/var aliases.
    atomic_store(&backgroundGuestImage, 0);
    free(backgroundGuestExecutablePath);
    NSString *path = @(guest.dli_fname);
    backgroundGuestExecutablePath = strdup([[path.stringByDeletingLastPathComponent
        stringByAppendingFormat:@"/./%@", path.lastPathComponent] fileSystemRepresentation]);
    LCBackgroundAudioImageAdded(guest.dli_fbase, 0);
    XCTAssertEqual(atomic_load(&backgroundGuestImage), (uintptr_t)guest.dli_fbase);
}
- (void)testOriginalQueryExceptionsStillReachCaller {
    LCTestBackgroundSession *session = self.session;
    session.throwOnQuery = YES;
    XCTAssertThrowsSpecificNamed(LCTestGuestAudioQuery(session), NSException, @"LCTestBackgroundQuery");
    session.throwOnQuery = NO;
    XCTAssertFalse(LCTestGuestAudioQuery(session));
    XCTAssertEqual(session.queryCalls, 2u);
}
@end
