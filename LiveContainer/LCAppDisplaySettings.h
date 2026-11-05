#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCAppInterfaceMode) {
    LCAppInterfaceModeAutomatic = 0,
    LCAppInterfaceModePhone = 1,
    LCAppInterfaceModePad = 2,
};

static NSString * const LCAppInterfaceModeKey = @"LCAppInterfaceMode";
static NSString * const LCAppWindowAspectRatioKey = @"LCAppWindowAspectRatio";

static inline LCAppInterfaceMode LCAppInterfaceModeFromInfo(NSDictionary *info) {
    id value = info[LCAppInterfaceModeKey];
    if ([value isKindOfClass:NSNumber.class]) {
        if ([value isEqual:@(LCAppInterfaceModePhone)]) return LCAppInterfaceModePhone;
        if ([value isEqual:@(LCAppInterfaceModePad)]) return LCAppInterfaceModePad;
    }
    return LCAppInterfaceModeAutomatic;
}

// Width:height, without orientation-dependent swapping. Zero means fill.
// Bound both components and the quotient to avoid degenerate layout constraints.
static inline BOOL LCAppAspectRatioIsValid(CGSize ratio) {
    return isfinite(ratio.width) && isfinite(ratio.height) &&
        ratio.width >= 1 && ratio.height >= 1 && ratio.width <= 10000 && ratio.height <= 10000 &&
        ratio.width / ratio.height >= 0.1 && ratio.width / ratio.height <= 10;
}

static inline CGSize LCAppAspectRatioFromInfo(NSDictionary *info) {
    id value = info[LCAppWindowAspectRatioKey];
    if (![value isKindOfClass:NSArray.class] || [value count] != 2 ||
        ![value[0] isKindOfClass:NSNumber.class] || ![value[1] isKindOfClass:NSNumber.class]) return CGSizeZero;
    CGSize ratio = CGSizeMake([value[0] doubleValue], [value[1] doubleValue]);
    return LCAppAspectRatioIsValid(ratio) ? ratio : CGSizeZero;
}

static inline BOOL LCAppDisplayUsesWindowScreenSize(NSDictionary *info) {
    return [info[@"LCUseWindowScreenSize"] isEqual:@YES] || LCAppAspectRatioIsValid(LCAppAspectRatioFromInfo(info));
}

// Freeze host/guest choices for this launch so an edit while an account starts
// cannot give its host one ratio and its guest another. Older hosts use appInfo.
static inline NSDictionary *LCAppDisplaySettingsForLaunch(NSDictionary *appInfo, NSDictionary * _Nullable launchInfo) {
    id snapshot = launchInfo[@"appDisplaySettings"];
    return [snapshot isKindOfClass:NSDictionary.class] ? snapshot : appInfo;
}

static inline NSDictionary *LCAppDisplaySettingsSnapshot(NSDictionary *info) {
    CGSize ratio = LCAppAspectRatioFromInfo(info);
    return @{LCAppInterfaceModeKey: @(LCAppInterfaceModeFromInfo(info)),
             LCAppWindowAspectRatioKey: @[@(ratio.width), @(ratio.height)],
             @"LCUseWindowScreenSize": @([info[@"LCUseWindowScreenSize"] isEqual:@YES])};
}

NS_ASSUME_NONNULL_END
