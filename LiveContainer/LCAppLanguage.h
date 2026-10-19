#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCAppLanguage : NSObject
@property(class, nonatomic, readonly) NSString *traditionalCantoneseIdentifier;

+ (NSArray<NSString *> *)availableLanguagesInBundle:(NSBundle *)bundle
                                  selectedLanguage:(nullable NSString *)selectedLanguage
    NS_SWIFT_NAME(availableLanguages(in:selectedLanguage:));
+ (BOOL)isTraditionalCantonese:(NSString *)language;
+ (NSArray<NSString *> *)preferredLanguagesForSelection:(nullable NSString *)selectedLanguage
    NS_SWIFT_NAME(preferredLanguages(for:));
@end

NS_ASSUME_NONNULL_END
