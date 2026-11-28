#import <XCTest/XCTest.h>
#define LC_AMBIENT_AUDIO_TESTING 1
#import "../LiveContainer/Tweaks/AmbientAudio.m"

// A forwarding session exercises nested convenience setters and preserves
// errors without activating audio in the XCTest host.
@interface LCTestAmbientSession : NSObject
@property(nonatomic, copy) NSString *category, *mode;
@property(nonatomic) AVAudioSessionCategoryOptions options;
@property(nonatomic) AVAudioSessionRouteSharingPolicy policy;
@property(nonatomic) NSUInteger mutations, activeCalls;
@property(nonatomic) BOOL reject, throwOnSet;
@property(nonatomic, strong) NSError *failure;
- (BOOL)setCategory:(NSString *)category error:(NSError **)error;
- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy
             options:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setMode:(NSString *)mode error:(NSError **)error;
- (BOOL)setActive:(BOOL)active error:(NSError **)error;
@end
@implementation LCTestAmbientSession
- (BOOL)setCategory:(NSString *)category error:(NSError **)error {
    self.mutations++;
    if (self.throwOnSet) [NSException raise:@"LCTestAudioFailure" format:@"Test exception"];
    if (self.reject) { if (error) *error = self.failure; return NO; }
    self.category = category;
    return YES;
}
- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)error {
    BOOL success = [self setCategory:category error:error];
    if (success) self.options = options;
    return success;
}
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)error {
    return [self setCategory:category mode:mode routeSharingPolicy:AVAudioSessionRouteSharingPolicyDefault options:options error:error];
}
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy
             options:(AVAudioSessionCategoryOptions)options error:(NSError **)error {
    if (![self setCategory:category withOptions:options error:error]) return NO;
    self.mode = mode;
    self.policy = policy;
    return YES;
}
- (BOOL)setMode:(NSString *)mode error:(NSError **)error {
    self.mutations++;
    if (self.reject) { if (error) *error = self.failure; return NO; }
    self.mode = mode;
    return YES;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)error { self.activeCalls++; return YES; }
@end

static uint32_t testLegacyProperty, testLegacySize, testLegacyValue;
static NSUInteger testLegacyCalls;
static const void *testLegacyData;
static int32_t LCTestLegacySet(uint32_t property, uint32_t size, const void *data) {
    testLegacyProperty = property; testLegacySize = size; testLegacyData = data;
    if (size == sizeof(uint32_t) && data) memcpy(&testLegacyValue, data, size);
    testLegacyCalls++;
    return -43;
}

@interface AmbientAudioTests : XCTestCase
@end
@implementation AmbientAudioTests
- (void)setUp {
    [super setUp];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ XCTAssertTrue(LCAmbientHookClass(LCTestAmbientSession.class)); });
    originalLegacyProperty = LCTestLegacySet;
    testLegacyCalls = 0;
    XCTAssertEqual(ambientSetterDepth, 0u);
}
- (void)tearDown {
    XCTAssertEqual(ambientSetterDepth, 0u);
    [super tearDown];
}
- (void)testOptInAppliesOnlyToInjectedVirtualGuests {
    NSDictionary *enabled = @{@"LCForceAmbientAudio": @YES};
    NSDictionary *virtual = @{@"virtualWindow": @YES};
    XCTAssertTrue(LCAmbientAudioShouldEnable(YES, @"game", enabled, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(NO, @"game", enabled, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, nil, enabled, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"", enabled, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"game", @{}, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"game", @{@"LCForceAmbientAudio": @NO}, virtual));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"game", enabled, nil));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"game", enabled, @{@"virtualWindow": @NO}));
    XCTAssertFalse(LCAmbientAudioShouldEnable(YES, @"game", @{@"LCForceAmbientAudio": @YES, @"dontInjectTweakLoader": @YES}, virtual));
}
- (void)testEveryPlaybackSetterStaysAmbientThroughNestedOriginalCalls {
    for (NSString *category in @[AVAudioSessionCategoryAmbient, AVAudioSessionCategorySoloAmbient, AVAudioSessionCategoryPlayback]) {
        for (NSInteger variant = 0; variant < 4; variant++) {
            LCTestAmbientSession *session = [LCTestAmbientSession new];
            NSError *error = nil;
            BOOL result;
            AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDuckOthers;
            switch (variant) {
                case 0: result = [session setCategory:category error:&error]; break;
                case 1: result = [session setCategory:category withOptions:options error:&error]; break;
                case 2: result = [session setCategory:category mode:AVAudioSessionModeMoviePlayback options:options error:&error]; break;
                default: result = [session setCategory:category mode:AVAudioSessionModeMoviePlayback
                    routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongFormAudio options:options error:&error]; break;
            }
            XCTAssertTrue(result);
            XCTAssertNil(error);
            XCTAssertEqualObjects(session.category, AVAudioSessionCategoryAmbient);
            XCTAssertEqualObjects(session.mode, AVAudioSessionModeDefault);
            XCTAssertEqual(session.options, 0u);
            XCTAssertEqual(session.policy, AVAudioSessionRouteSharingPolicyDefault);
            XCTAssertEqual(session.mutations, 1u);
            XCTAssertEqual(session.activeCalls, 0u);
            XCTAssertTrue([session setMode:AVAudioSessionModeMoviePlayback error:&error]);
            XCTAssertEqualObjects(session.mode, AVAudioSessionModeDefault);
        }
    }
}
- (void)testRecordingAndUnknownCategoriesPreserveModePolicyAndOptions {
    for (NSString *category in @[AVAudioSessionCategoryRecord, AVAudioSessionCategoryPlayAndRecord,
                                 AVAudioSessionCategoryMultiRoute, @"FutureCategory"]) {
        LCTestAmbientSession *session = [LCTestAmbientSession new];
        NSError *error = nil;
        AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers;
        XCTAssertTrue([session setCategory:category mode:AVAudioSessionModeVoiceChat
            routeSharingPolicy:AVAudioSessionRouteSharingPolicyDefault options:options error:&error]);
        XCTAssertEqualObjects(session.category, category);
        XCTAssertEqualObjects(session.mode, AVAudioSessionModeVoiceChat);
        XCTAssertEqual(session.options, options);
        XCTAssertEqual(session.mutations, 1u);
        XCTAssertTrue([session setMode:AVAudioSessionModeMeasurement error:&error]);
        XCTAssertEqualObjects(session.mode, AVAudioSessionModeMeasurement);
    }
}
- (void)testFailureAndExceptionKeepOriginalResultAndClearReentryGuard {
    LCTestAmbientSession *session = [LCTestAmbientSession new];
    session.failure = [NSError errorWithDomain:@"LCTestAudio" code:73 userInfo:nil];
    session.reject = YES;
    NSError *error = nil;
    XCTAssertFalse([session setCategory:AVAudioSessionCategoryPlayback error:&error]);
    XCTAssertEqual(error, session.failure);
    XCTAssertEqual(session.mutations, 1u);
    XCTAssertEqual(ambientSetterDepth, 0u);
    session.reject = NO;
    session.throwOnSet = YES;
    XCTAssertThrows([session setCategory:AVAudioSessionCategorySoloAmbient error:nil]);
    XCTAssertEqual(ambientSetterDepth, 0u);
    session.throwOnSet = NO;
    XCTAssertTrue([session setCategory:AVAudioSessionCategoryPlayback error:nil]);
    XCTAssertEqualObjects(session.category, AVAudioSessionCategoryAmbient);
}
- (void)testLegacyOutputCategoriesConvertWithoutSwallowingErrors {
    for (uint32_t category = 0, index = 0; index < 3; index++) {
        const uint32_t categories[] = {0x616d6269, 0x736f6c6f, 0x6d656469};
        category = categories[index];
        XCTAssertEqual(LCAmbientSetLegacyProperty(0x61636174, sizeof(category), &category), -43);
        XCTAssertEqual(testLegacyValue, 0x616d6269u);
        XCTAssertEqual(testLegacyProperty, 0x61636174u);
        XCTAssertEqual(testLegacySize, sizeof(category));
        XCTAssertEqual(category, categories[index]);
    }
    XCTAssertEqual(testLegacyCalls, 3u);
    uint32_t input = 0x72656361; // 'reca'
    XCTAssertEqual(LCAmbientSetLegacyProperty(0x61636174, sizeof(input), &input), -43);
    XCTAssertEqual(testLegacyValue, input);
    XCTAssertEqual(testLegacyData, &input);
    XCTAssertEqual(LCAmbientSetLegacyProperty(0x636d6978, sizeof(input), &input), -43);
    XCTAssertEqual(testLegacyData, &input);
    XCTAssertEqual(LCAmbientSetLegacyProperty(0x61636174, 1, &input), -43);
    XCTAssertEqual(testLegacySize, 1u);
    XCTAssertEqual(testLegacyData, &input);
    XCTAssertEqual(LCAmbientSetLegacyProperty(0x61636174, 4, NULL), -43);
    XCTAssertEqual(testLegacyData, NULL);
}
@end
