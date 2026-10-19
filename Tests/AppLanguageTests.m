#import "../LiveContainer/LCAppLanguage.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void assertFirstLocalization(NSArray<NSString *> *available, NSString *selection, NSString *expected) {
    NSArray<NSString *> *preferences = [LCAppLanguage preferredLanguagesForSelection:selection];
    NSArray<NSString *> *resolved = [NSBundle preferredLocalizationsFromArray:available forPreferences:preferences];
    if (![resolved.firstObject isEqualToString:expected]) {
        NSLog(@"For %@ in %@, expected %@ but Foundation resolved %@", selection, available, expected, resolved);
        abort();
    }
}

static void testLanguageResolution(void) {
    assert([LCAppLanguage preferredLanguagesForSelection:nil].count == 0);
    assert([LCAppLanguage preferredLanguagesForSelection:@""].count == 0);

    // An explicit language must not pick up Cantonese's fallback chain.
    for (NSString *language in @[@"en", @"ja", @"zh-Hans", @"yue-Hans", @"yue-Hans-HK"]) {
        assert(![LCAppLanguage isTraditionalCantonese:language]);
        assert([[LCAppLanguage preferredLanguagesForSelection:language] isEqualToArray:@[language]]);
    }

    // Exercise Foundation's actual matching, including legacy Chinese region identifiers.
    for (NSString *selection in @[@"yue-Hant", @"yue_Hant", @"yue-Hant-HK", @"yue_Hant_HK", @"yue-HK", @"yue-MO"]) {
        assert([LCAppLanguage isTraditionalCantonese:selection]);
        assertFirstLocalization(@[@"en", @"zh-Hant", @"yue-Hant"], selection, @"yue-Hant");
        assertFirstLocalization(@[@"en", @"zh-Hant", @"yue"], selection, @"yue");
        assertFirstLocalization(@[@"en", @"zh-Hant", @"zh-Hant-HK"], selection, @"zh-Hant-HK");
        assertFirstLocalization(@[@"en", @"zh-Hans", @"zh-Hant"], selection, @"zh-Hant");
        assertFirstLocalization(@[@"en", @"zh-Hans", @"zh-HK"], selection, @"zh-HK");
        assertFirstLocalization(@[@"en", @"zh-Hans", @"zh-TW"], selection, @"zh-TW");
        assertFirstLocalization(@[@"en", @"zh-Hans", @"zh-Hant-TW"], selection, @"zh-Hant-TW");
    }
    assertFirstLocalization(@[@"en", @"yue-Hant", @"yue-Hant-HK"], @"yue-Hant-HK", @"yue-Hant-HK");
    assertFirstLocalization(@[@"en", @"zh-Hans", @"zh-Hant"], @"zh-Hans", @"zh-Hans");
}

static NSBundle *makeBundle(NSURL *root, NSArray<NSString *> *resources, NSArray<NSString *> *declared) {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSURL *url = [root URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"bundle"]];
    NSURL *contentsURL = [url URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    NSURL *resourcesURL = [contentsURL URLByAppendingPathComponent:@"Resources" isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    assert([fm createDirectoryAtURL:resourcesURL withIntermediateDirectories:YES attributes:nil error:NULL]);
    for (NSString *language in resources) {
        NSURL *localizationURL = [resourcesURL URLByAppendingPathComponent:[language stringByAppendingPathExtension:@"lproj"]];
        assert([fm createDirectoryAtURL:localizationURL withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert([@{@"test": language} writeToURL:[localizationURL URLByAppendingPathComponent:@"Localizable.strings"] atomically:YES]);
    }
    NSDictionary *info = @{
        @"CFBundleIdentifier": [@"org.livecontainer.language-tests." stringByAppendingString:identifier],
        @"CFBundlePackageType": @"BNDL",
        @"CFBundleDevelopmentRegion": @"en",
        @"CFBundleLocalizations": declared
    };
    assert([info writeToURL:[contentsURL URLByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    assert(bundle != nil);
    return bundle;
}

static void assertUniqueLanguages(NSArray<NSString *> *languages) {
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (NSString *language in languages) {
        assert(language.length > 0);
        assert([language caseInsensitiveCompare:@"Base"] != NSOrderedSame);
        NSString *canonical = [NSLocale canonicalLanguageIdentifierFromString:language].lowercaseString;
        assert(![identifiers containsObject:canonical]);
        [identifiers addObject:canonical];
    }
}

static void testBundleLanguages(NSURL *root) {
    NSBundle *bundle = makeBundle(root, @[@"Base", @"en", @"zh-Hant"], @[@"fr", @"yue_Hant", @"zh-Hant"]);
    NSArray<NSString *> *languages = [LCAppLanguage availableLanguagesInBundle:bundle selectedLanguage:nil];
    for (NSString *language in @[@"en", @"fr", @"zh-Hant", @"yue-Hant"]) {
        assert([languages containsObject:language]);
    }
    assertUniqueLanguages(languages);

    // Updating an app can remove a localization; keep the persisted picker value visible.
    languages = [LCAppLanguage availableLanguagesInBundle:bundle selectedLanguage:@"de-DE"];
    assert([languages containsObject:@"de-DE"]);
    assertUniqueLanguages(languages);
    for (NSString *selection in @[@"yue_Hant", @"zh_Hant"]) {
        languages = [LCAppLanguage availableLanguagesInBundle:bundle selectedLanguage:selection];
        assert([languages containsObject:selection]);
        assertUniqueLanguages(languages);
    }
    assertUniqueLanguages([LCAppLanguage availableLanguagesInBundle:bundle selectedLanguage:@"Base"]);

    NSBundle *declaredOnly = makeBundle(root, @[], @[@"en", @"fr"]);
    languages = [LCAppLanguage availableLanguagesInBundle:declaredOnly selectedLanguage:@""];
    assert([languages containsObject:@"fr"]);
    assert([languages containsObject:@"yue-Hant"]);
    assertUniqueLanguages(languages);

    NSBundle *resourcesOnly = makeBundle(root, @[@"Base", @"en", @"ja"], @[]);
    languages = [LCAppLanguage availableLanguagesInBundle:resourcesOnly selectedLanguage:nil];
    assert([languages containsObject:@"ja"]);
    assert([languages containsObject:@"yue-Hant"]);
    assertUniqueLanguages(languages);
}

int main(void) {
    @autoreleasepool {
        testLanguageResolution();
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:[@"LCAppLanguageTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        testBundleLanguages(root);
        assert([fm removeItemAtURL:root error:NULL]);
        puts("App language tests passed (Foundation locale matching, bundle discovery, saved selections and automatic mode).");
    }
    return 0;
}
