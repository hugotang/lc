#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const LCAppLocationKey = @"LCAppLocation";

static inline BOOL LCAppLocationCoordinateIsValid(CLLocationCoordinate2D coordinate) {
    return isfinite(coordinate.latitude) && isfinite(coordinate.longitude) &&
        coordinate.latitude >= -90 && coordinate.latitude <= 90 &&
        coordinate.longitude >= -180 && coordinate.longitude <= 180;
}

// An absent location is distinct from the valid coordinate (0, 0).
static inline NSDictionary *LCAppLocationSettings(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    id latitude = value[@"latitude"], longitude = value[@"longitude"];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)latitude) == CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)longitude) == CFBooleanGetTypeID()) return @{};
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([latitude doubleValue], [longitude doubleValue]);
    if (!LCAppLocationCoordinateIsValid(coordinate)) return @{};
    NSString *name = [value[@"name"] isKindOfClass:NSString.class] ? value[@"name"] : @"";
    if (name.length > 200) name = [name substringToIndex:200];
    return @{@"enabled": @([value[@"enabled"] isEqual:@YES]), @"latitude": @(coordinate.latitude),
             @"longitude": @(coordinate.longitude), @"name": name};
}

static inline BOOL LCAppLocationShouldEnable(NSString * _Nullable guestAppId, BOOL sideStore, NSDictionary *info) {
    return guestAppId.length && !sideStore && ![info[@"is32bit"] boolValue] &&
        ![info[@"dontInjectTweakLoader"] boolValue] &&
        [LCAppLocationSettings(info[LCAppLocationKey])[@"enabled"] boolValue];
}

NS_ASSUME_NONNULL_END
