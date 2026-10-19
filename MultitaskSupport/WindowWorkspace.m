#import "WindowWorkspace.h"
#include <math.h>

static BOOL LCWorkspaceNameIsValid(id value, BOOL singleComponent) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 1024 ||
        [value isAbsolutePath] || [value containsString:@"\\"]) return NO;
    NSArray *components = [value componentsSeparatedByString:@"/"];
    if (singleComponent && components.count != 1) return NO;
    for (NSString *part in components) {
        if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

@implementation LCWorkspaceWindow
- (instancetype)initWithBundleName:(NSString *)bundleName dataUUID:(NSString *)dataUUID scale:(double)scale {
    if (!LCWorkspaceNameIsValid(bundleName, NO) || !LCWorkspaceNameIsValid(dataUUID, YES) ||
        !isfinite(scale) || scale < 0.5 || scale > 2.0) return nil;
    self = [super init];
    if (self) {
        _bundleName = bundleName.copy;
        _dataUUID = dataUUID.copy;
        _scale = scale;
    }
    return self;
}
- (NSDictionary *)propertyList {
    return @{@"bundleName": self.bundleName, @"dataUUID": self.dataUUID, @"scale": @(self.scale)};
}
@end

static NSArray<NSNumber *> *LCWorkspaceDividers(id value, NSUInteger tracks) {
    if (![value isKindOfClass:NSArray.class] || [value count] != tracks - 1) return nil;
    double previous = 0;
    NSMutableArray *result = [NSMutableArray array];
    for (id number in value) {
        if (![number isKindOfClass:NSNumber.class]) return nil;
        double fraction = [number doubleValue];
        if (!isfinite(fraction) || fraction <= previous || fraction >= 1) return nil;
        [result addObject:@(fraction)];
        previous = fraction;
    }
    return result.copy;
}

static NSDictionary *LCWorkspaceProportions(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in value) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@":"];
        if (parts.count != 4) continue;
        BOOL valid = YES;
        for (NSString *part in parts) {
            if (![part isEqualToString:@(part.integerValue).stringValue]) valid = NO;
        }
        NSInteger count = parts[0].integerValue, rows = parts[1].integerValue, columns = parts[2].integerValue;
        NSInteger portrait = parts[3].integerValue;
        if (!valid || count < 1 || count > 64 || rows < 1 || rows > count || columns < 1 || columns > count ||
            (portrait != 0 && portrait != 1) || (rows - 1) * columns >= count || rows * columns < count) continue;
        id entry = value[key];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSArray *rowDividers = LCWorkspaceDividers(entry[@"rows"], rows);
        NSArray *columnDividers = LCWorkspaceDividers(entry[@"columns"], columns);
        NSArray *lastRowDividers = LCWorkspaceDividers(entry[@"lastRowColumns"], count - (rows - 1) * columns);
        if (rowDividers && columnDividers && lastRowDividers) {
            result[key] = @{@"rows": rowDividers, @"columns": columnDividers, @"lastRowColumns": lastRowDividers};
        }
    }
    return result.copy;
}

@implementation LCWindowWorkspace
- (instancetype)initWithPropertyList:(id)propertyList {
    if (![propertyList isKindOfClass:NSDictionary.class] || ![propertyList[@"version"] isEqual:@1]) return nil;
    id entries = propertyList[@"windows"];
    if (![entries isKindOfClass:NSArray.class] || [entries count] == 0 || [entries count] > 64) return nil;
    NSMutableArray *windows = [NSMutableArray array];
    NSMutableSet *containers = [NSMutableSet set];
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"scale"] isKindOfClass:NSNumber.class]) return nil;
        LCWorkspaceWindow *window = [[LCWorkspaceWindow alloc] initWithBundleName:entry[@"bundleName"]
                                                                       dataUUID:entry[@"dataUUID"] scale:[entry[@"scale"] doubleValue]];
        if (!window || [containers containsObject:window.dataUUID]) return nil;
        [containers addObject:window.dataUUID];
        [windows addObject:window];
    }
    self = [super init];
    if (self) {
        _windows = windows.copy;
        _proportions = LCWorkspaceProportions(propertyList[@"proportions"]);
    }
    return self;
}
- (instancetype)initWithWindows:(NSArray<LCWorkspaceWindow *> *)windows proportions:(NSDictionary *)proportions {
    NSMutableArray *entries = [NSMutableArray array];
    for (LCWorkspaceWindow *window in windows) [entries addObject:window.propertyList];
    return [self initWithPropertyList:@{@"version": @1, @"windows": entries, @"proportions": proportions}];
}
- (NSDictionary *)propertyList {
    NSMutableArray *entries = [NSMutableArray array];
    for (LCWorkspaceWindow *window in self.windows) [entries addObject:window.propertyList];
    return @{@"version": @1, @"windows": entries.copy, @"proportions": self.proportions};
}
@end
