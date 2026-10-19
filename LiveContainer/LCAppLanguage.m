#import "LCAppLanguage.h"

@implementation LCAppLanguage

+ (NSString *)traditionalCantoneseIdentifier {
    return @"yue-Hant";
}

+ (NSArray<NSString *> *)availableLanguagesInBundle:(NSBundle *)bundle
                                  selectedLanguage:(NSString *)selectedLanguage {
    NSMutableDictionary<NSString *, NSString *> *languages = [NSMutableDictionary dictionary];
    // NSBundle includes both .lproj resources and CFBundleLocalizations declarations.
    for (NSString *language in bundle.localizations) {
        if (language.length == 0 || [language caseInsensitiveCompare:@"Base"] == NSOrderedSame) continue;
        NSString *key = [NSLocale canonicalLanguageIdentifierFromString:language].lowercaseString;
        if (!languages[key]) languages[key] = language;
    }
    languages[self.traditionalCantoneseIdentifier.lowercaseString] = self.traditionalCantoneseIdentifier;
    if (selectedLanguage.length > 0 && [selectedLanguage caseInsensitiveCompare:@"Base"] != NSOrderedSame) {
        // Keep the exact stored identifier selected, even after an app changes its resources.
        NSString *key = [NSLocale canonicalLanguageIdentifierFromString:selectedLanguage].lowercaseString;
        languages[key] = selectedLanguage;
    }
    return [languages.allValues sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (BOOL)isTraditionalCantonese:(NSString *)language {
    NSString *identifier = [NSLocale canonicalLanguageIdentifierFromString:language];
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:identifier];
    if (![locale.languageCode isEqualToString:@"yue"]) return NO;
    return [locale.scriptCode isEqualToString:@"Hant"] ||
        (locale.scriptCode.length == 0 &&
         ([locale.countryCode isEqualToString:@"HK"] || [locale.countryCode isEqualToString:@"MO"]));
}

+ (NSArray<NSString *> *)preferredLanguagesForSelection:(NSString *)selectedLanguage {
    if (selectedLanguage.length == 0) return @[];
    if (![self isTraditionalCantonese:selectedLanguage]) return @[selectedLanguage];

    // Cantonese and Chinese use different language codes. Supply explicit script fallbacks
    // for apps that have Traditional Chinese translations but no Cantonese localization.
    NSMutableOrderedSet<NSString *> *languages = [NSMutableOrderedSet orderedSetWithObject:selectedLanguage];
    [languages addObjectsFromArray:@[self.traditionalCantoneseIdentifier, @"zh-Hant-HK", @"zh-Hant"]];
    return languages.array;
}

@end
