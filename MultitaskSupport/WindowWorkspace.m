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

static BOOL LCWorkspaceBoolean(id value, BOOL fallback) {
    if ([value isKindOfClass:NSNumber.class]) {
        if ([value isEqual:@YES]) return YES;
        if ([value isEqual:@NO]) return NO;
    }
    return fallback;
}

static NSDictionary *LCWorkspaceTapSyncGroup(id value, NSArray<LCWorkspaceWindow *> *windows) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"source"] isKindOfClass:NSString.class] ||
        ![value[@"targets"] isKindOfClass:NSArray.class]) return @{};
    NSMutableDictionary<NSString *, LCWorkspaceWindow *> *byContainer = [NSMutableDictionary dictionary];
    for (LCWorkspaceWindow *window in windows) byContainer[window.dataUUID] = window;
    LCWorkspaceWindow *source = byContainer[value[@"source"]];
    NSArray *targets = value[@"targets"];
    if (!source || targets.count == 0 || targets.count > 63) return @{};
    NSMutableArray *validTargets = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet setWithObject:source.dataUUID];
    for (id target in targets) {
        if (![target isKindOfClass:NSString.class] || [seen containsObject:target]) return @{};
        LCWorkspaceWindow *window = byContainer[target];
        if (!window || ![window.bundleName isEqualToString:source.bundleName]) return @{};
        [seen addObject:target];
        [validTargets addObject:window.dataUUID];
    }
    NSMutableDictionary *group = [@{@"source": source.dataUUID, @"targets": validTargets.copy} mutableCopy];
    // Older or unknown modes use the conservative tap-only behavior.
    if ([value[@"mode"] isEqual:@"singleFinger"]) group[@"mode"] = @"singleFinger";
    if ([value[@"mode"] isEqual:@"twoFingers"]) group[@"mode"] = @"twoFingers";
    return group.copy;
}

static const LCWorkspaceLayoutPreference LCGridLayoutPreferences[] = {
    LCWorkspaceLayoutPreferenceSingleRowInLandscape,
    LCWorkspaceLayoutPreferenceReservePortraitTop,
    LCWorkspaceLayoutPreferenceReservePortraitBottom,
    LCWorkspaceLayoutPreferenceReserveLandscapeTop,
    LCWorkspaceLayoutPreferenceReserveLandscapeBottom,
};
static const size_t LCGridLayoutPreferenceCount = sizeof(LCGridLayoutPreferences) / sizeof(LCGridLayoutPreferences[0]);

// Saved workspaces use these property-list keys; the live preferences use the
// userDefaultsKeyForPreference: keys.
static NSString *LCGridLayoutPropertyListKey(LCWorkspaceLayoutPreference preference) {
    switch (preference) {
        case LCWorkspaceLayoutPreferenceSingleRowInLandscape: return @"singleRowInLandscape";
        case LCWorkspaceLayoutPreferenceReservePortraitTop: return @"reservePortraitTop";
        case LCWorkspaceLayoutPreferenceReservePortraitBottom: return @"reservePortraitBottom";
        case LCWorkspaceLayoutPreferenceReserveLandscapeTop: return @"reserveLandscapeTop";
        case LCWorkspaceLayoutPreferenceReserveLandscapeBottom: return @"reserveLandscapeBottom";
    }
    return nil;
}

static bool *LCGridReservedArea(LCWindowGridReservedAreas *areas, LCWorkspaceLayoutPreference preference) {
    switch (preference) {
        case LCWorkspaceLayoutPreferenceReservePortraitTop: return &areas->portraitTop;
        case LCWorkspaceLayoutPreferenceReservePortraitBottom: return &areas->portraitBottom;
        case LCWorkspaceLayoutPreferenceReserveLandscapeTop: return &areas->landscapeTop;
        case LCWorkspaceLayoutPreferenceReserveLandscapeBottom: return &areas->landscapeBottom;
        default: return NULL;
    }
}

@interface LCGridLayoutOptions ()
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *propertyListEntries;
@end

@implementation LCGridLayoutOptions
+ (LCGridLayoutOptions *)defaultOptions {
    return [[self alloc] initWithSingleRowInLandscape:NO reservedAreas:LCWindowGridReservedAreasDefault()];
}
+ (NSString *)userDefaultsKeyForPreference:(LCWorkspaceLayoutPreference)preference {
    switch (preference) {
        case LCWorkspaceLayoutPreferenceSingleRowInLandscape: return @"LCGridSingleRowInLandscape";
        case LCWorkspaceLayoutPreferenceReservePortraitTop: return @"LCGridReservePortraitTop";
        case LCWorkspaceLayoutPreferenceReservePortraitBottom: return @"LCGridReservePortraitBottom";
        case LCWorkspaceLayoutPreferenceReserveLandscapeTop: return @"LCGridReserveLandscapeTop";
        case LCWorkspaceLayoutPreferenceReserveLandscapeBottom: return @"LCGridReserveLandscapeBottom";
    }
    [NSException raise:NSInvalidArgumentException format:@"Unknown grid layout preference %ld", (long)preference];
    return @"";
}
+ (BOOL)defaultValueForPreference:(LCWorkspaceLayoutPreference)preference {
    return [self.defaultOptions valueForPreference:preference];
}
- (instancetype)initWithSingleRowInLandscape:(BOOL)singleRowInLandscape reservedAreas:(LCWindowGridReservedAreas)reservedAreas {
    if ((self = [super init])) {
        _singleRowInLandscape = singleRowInLandscape;
        _reservedAreas = reservedAreas;
    }
    return self;
}
// Each preference starts at its default; value() may keep or replace it.
- (instancetype)initWithValues:(BOOL (^)(LCWorkspaceLayoutPreference preference, BOOL fallback))value {
    LCGridLayoutOptions *defaults = LCGridLayoutOptions.defaultOptions;
    LCWindowGridReservedAreas areas = defaults.reservedAreas;
    for (size_t index = 0; index < LCGridLayoutPreferenceCount; index++) {
        bool *area = LCGridReservedArea(&areas, LCGridLayoutPreferences[index]);
        if (area) *area = value(LCGridLayoutPreferences[index], *area);
    }
    return [self initWithSingleRowInLandscape:value(LCWorkspaceLayoutPreferenceSingleRowInLandscape, defaults.singleRowInLandscape)
                                reservedAreas:areas];
}
- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults {
    return [self initWithValues:^BOOL(LCWorkspaceLayoutPreference preference, BOOL fallback) {
        NSString *key = [LCGridLayoutOptions userDefaultsKeyForPreference:preference];
        return [defaults objectForKey:key] ? [defaults boolForKey:key] : fallback;
    }];
}
// Optional v1 fields preserve the original layout for older or malformed saves.
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList {
    return [self initWithValues:^BOOL(LCWorkspaceLayoutPreference preference, BOOL fallback) {
        return LCWorkspaceBoolean(propertyList[LCGridLayoutPropertyListKey(preference)], fallback);
    }];
}
- (void)writeToUserDefaults:(NSUserDefaults *)defaults {
    for (size_t index = 0; index < LCGridLayoutPreferenceCount; index++) {
        LCWorkspaceLayoutPreference preference = LCGridLayoutPreferences[index];
        [defaults setBool:[self valueForPreference:preference] forKey:[LCGridLayoutOptions userDefaultsKeyForPreference:preference]];
    }
}
- (NSDictionary<NSString *, NSNumber *> *)propertyListEntries {
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (size_t index = 0; index < LCGridLayoutPreferenceCount; index++) {
        LCWorkspaceLayoutPreference preference = LCGridLayoutPreferences[index];
        entries[LCGridLayoutPropertyListKey(preference)] = @([self valueForPreference:preference]);
    }
    return entries.copy;
}
- (BOOL)valueForPreference:(LCWorkspaceLayoutPreference)preference {
    if (preference == LCWorkspaceLayoutPreferenceSingleRowInLandscape) return self.singleRowInLandscape;
    LCWindowGridReservedAreas areas = self.reservedAreas;
    bool *area = LCGridReservedArea(&areas, preference);
    return area && *area;
}
- (LCGridLayoutOptions *)optionsBySettingPreference:(LCWorkspaceLayoutPreference)preference enabled:(BOOL)enabled {
    if (preference == LCWorkspaceLayoutPreferenceSingleRowInLandscape) {
        return [[LCGridLayoutOptions alloc] initWithSingleRowInLandscape:enabled reservedAreas:self.reservedAreas];
    }
    LCWindowGridReservedAreas areas = self.reservedAreas;
    bool *area = LCGridReservedArea(&areas, preference);
    if (!area) return nil;
    *area = enabled;
    return [[LCGridLayoutOptions alloc] initWithSingleRowInLandscape:self.singleRowInLandscape reservedAreas:areas];
}
- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:LCGridLayoutOptions.class]) return NO;
    LCGridLayoutOptions *other = object;
    return self.singleRowInLandscape == other.singleRowInLandscape &&
        LCWindowGridReservedAreasEqual(self.reservedAreas, other.reservedAreas);
}
- (NSUInteger)hash {
    LCWindowGridReservedAreas areas = self.reservedAreas;
    return (NSUInteger)self.singleRowInLandscape | ((NSUInteger)areas.portraitTop << 1) | ((NSUInteger)areas.portraitBottom << 2) |
        ((NSUInteger)areas.landscapeTop << 3) | ((NSUInteger)areas.landscapeBottom << 4);
}
@end

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
        _layoutOptions = [[LCGridLayoutOptions alloc] initWithPropertyList:propertyList];
        _tapSyncGroup = LCWorkspaceTapSyncGroup(propertyList[@"tapSync"], _windows);
    }
    return self;
}
- (instancetype)initWithWindows:(NSArray<LCWorkspaceWindow *> *)windows proportions:(NSDictionary *)proportions
                 layoutOptions:(LCGridLayoutOptions *)layoutOptions {
    NSMutableArray *entries = [NSMutableArray array];
    for (LCWorkspaceWindow *window in windows) [entries addObject:window.propertyList];
    NSMutableDictionary *propertyList = [@{@"version": @1, @"windows": entries, @"proportions": proportions} mutableCopy];
    [propertyList addEntriesFromDictionary:layoutOptions.propertyListEntries];
    return [self initWithPropertyList:propertyList];
}
- (BOOL)singleRowInLandscape { return self.layoutOptions.singleRowInLandscape; }
- (BOOL)reservePortraitTop { return self.layoutOptions.reservedAreas.portraitTop; }
- (BOOL)reservePortraitBottom { return self.layoutOptions.reservedAreas.portraitBottom; }
- (BOOL)reserveLandscapeTop { return self.layoutOptions.reservedAreas.landscapeTop; }
- (BOOL)reserveLandscapeBottom { return self.layoutOptions.reservedAreas.landscapeBottom; }
- (NSDictionary *)propertyList {
    NSMutableArray *entries = [NSMutableArray array];
    for (LCWorkspaceWindow *window in self.windows) [entries addObject:window.propertyList];
    NSMutableDictionary *result = [@{@"version": @1, @"windows": entries.copy, @"proportions": self.proportions} mutableCopy];
    [result addEntriesFromDictionary:self.layoutOptions.propertyListEntries];
    if (self.tapSyncGroup.count) result[@"tapSync"] = self.tapSyncGroup;
    return result.copy;
}
@end

static NSString *LCWorkspaceCanonicalID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 36) return nil;
    return [[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString;
}

static NSString *LCWorkspaceDisplayName(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0 || name.length > 80 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return name;
}

@interface LCNamedWorkspace ()
- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name snapshot:(LCWindowWorkspace *)snapshot;
- (NSDictionary *)propertyList;
@end

@implementation LCNamedWorkspace
- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name snapshot:(LCWindowWorkspace *)snapshot {
    NSString *validID = LCWorkspaceCanonicalID(identifier);
    NSString *validName = LCWorkspaceDisplayName(name);
    if (!validID || !validName || !snapshot) return nil;
    self = [super init];
    if (self) {
        _identifier = validID;
        _name = validName.copy;
        _snapshot = snapshot;
    }
    return self;
}
- (NSDictionary *)propertyList {
    return @{@"id": self.identifier, @"name": self.name, @"snapshot": self.snapshot.propertyList};
}
@end

@interface LCWorkspaceLibrary ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy) NSString *legacyName;
- (void)persist;
@end

@implementation LCWorkspaceLibrary
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults legacyName:(NSString *)legacyName {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults;
    _legacyName = legacyName.copy;
    id stored = [defaults objectForKey:@"LCWorkspaceLibrary"];
    NSMutableArray *entries = [NSMutableArray array];
    if (stored) {
        // Never replace an unreadable library with an empty save or re-import its legacy backup.
        if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"version"] isEqual:@1] ||
            ![stored[@"workspaces"] isKindOfClass:NSArray.class]) return nil;
        NSMutableSet *identifiers = [NSMutableSet set];
        for (id value in stored[@"workspaces"]) {
            if (![value isKindOfClass:NSDictionary.class]) return nil;
            LCWindowWorkspace *snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:value[@"snapshot"]];
            LCNamedWorkspace *entry = [[LCNamedWorkspace alloc] initWithIdentifier:value[@"id"] name:value[@"name"] snapshot:snapshot];
            if (!entry || [identifiers containsObject:entry.identifier]) return nil;
            for (LCNamedWorkspace *existing in entries) {
                if ([existing.name caseInsensitiveCompare:entry.name] == NSOrderedSame) return nil;
            }
            [identifiers addObject:entry.identifier];
            [entries addObject:entry];
        }
    } else {
        id legacy = [defaults objectForKey:@"LCWindowWorkspace"];
        if (legacy) {
            LCWindowWorkspace *snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:legacy];
            LCNamedWorkspace *entry = [[LCNamedWorkspace alloc] initWithIdentifier:NSUUID.UUID.UUIDString name:legacyName snapshot:snapshot];
            if (!entry) return nil;
            [entries addObject:entry];
        }
    }
    _workspaces = entries.copy;
    // The old snapshot stays available as a backup. An empty new library prevents re-import after deletion.
    if (!stored) [self persist];
    return self;
}

- (BOOL)reload {
    LCWorkspaceLibrary *current = [[LCWorkspaceLibrary alloc] initWithDefaults:self.defaults legacyName:self.legacyName];
    if (!current) return NO;
    _workspaces = current.workspaces;
    return YES;
}

- (LCNamedWorkspace *)workspaceWithIdentifier:(NSString *)identifier {
    if (!identifier) return self.workspaces.firstObject;
    NSString *canonical = LCWorkspaceCanonicalID(identifier);
    if (!canonical) return nil;
    for (LCNamedWorkspace *entry in self.workspaces) {
        if ([entry.identifier isEqualToString:canonical]) return entry;
    }
    return nil;
}

- (BOOL)canUseName:(NSString *)name excludingIdentifier:(NSString *)identifier {
    NSString *valid = LCWorkspaceDisplayName(name);
    if (!valid) return NO;
    NSString *canonical = LCWorkspaceCanonicalID(identifier);
    for (LCNamedWorkspace *entry in self.workspaces) {
        if (![entry.identifier isEqualToString:canonical] && [entry.name caseInsensitiveCompare:valid] == NSOrderedSame) return NO;
    }
    return YES;
}

- (LCNamedWorkspace *)saveWorkspace:(LCWindowWorkspace *)snapshot name:(NSString *)name replacingIdentifier:(NSString *)identifier {
    if (![self reload]) return nil;
    LCNamedWorkspace *existing = identifier ? [self workspaceWithIdentifier:identifier] : nil;
    if ((identifier && !existing) || ![self canUseName:name excludingIdentifier:identifier]) return nil;
    LCNamedWorkspace *entry = [[LCNamedWorkspace alloc] initWithIdentifier:existing ? existing.identifier : NSUUID.UUID.UUIDString
                                                                   name:name snapshot:snapshot];
    if (!entry) return nil;
    NSMutableArray *entries = self.workspaces.mutableCopy;
    if (existing) [entries removeObjectIdenticalTo:existing];
    [entries insertObject:entry atIndex:0];
    _workspaces = entries.copy;
    [self persist];
    return entry;
}

- (BOOL)renameWorkspace:(NSString *)identifier name:(NSString *)name {
    if (![self reload]) return NO;
    LCNamedWorkspace *existing = [self workspaceWithIdentifier:identifier];
    if (!identifier || !existing || ![self canUseName:name excludingIdentifier:identifier]) return NO;
    LCNamedWorkspace *entry = [[LCNamedWorkspace alloc] initWithIdentifier:existing.identifier name:name snapshot:existing.snapshot];
    if (!entry) return NO;
    NSMutableArray *entries = self.workspaces.mutableCopy;
    entries[[entries indexOfObjectIdenticalTo:existing]] = entry;
    _workspaces = entries.copy;
    [self persist];
    return YES;
}

- (BOOL)setLayoutPreference:(LCWorkspaceLayoutPreference)preference enabled:(BOOL)enabled forWorkspace:(NSString *)identifier {
    if (![self reload]) return NO;
    LCNamedWorkspace *existing = [self workspaceWithIdentifier:identifier];
    if (!identifier || !existing) return NO;
    LCWindowWorkspace *current = existing.snapshot;
    LCGridLayoutOptions *options = [current.layoutOptions optionsBySettingPreference:preference enabled:enabled];
    if (!options) return NO;
    if ([options isEqual:current.layoutOptions]) return YES;
    NSMutableDictionary *propertyList = current.propertyList.mutableCopy;
    [propertyList addEntriesFromDictionary:options.propertyListEntries];
    LCWindowWorkspace *snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:propertyList];
    LCNamedWorkspace *updated = [[LCNamedWorkspace alloc] initWithIdentifier:existing.identifier name:existing.name snapshot:snapshot];
    if (!updated) return NO;
    NSMutableArray *entries = self.workspaces.mutableCopy;
    entries[[entries indexOfObjectIdenticalTo:existing]] = updated;
    _workspaces = entries.copy;
    [self persist];
    return YES;
}

- (BOOL)setTapSyncGroup:(NSDictionary *)group forWorkspace:(NSString *)identifier {
    if (![self reload] || ![group isKindOfClass:NSDictionary.class]) return NO;
    LCNamedWorkspace *existing = [self workspaceWithIdentifier:identifier];
    if (!identifier || !existing) return NO;
    if (group[@"mode"] && ![group[@"mode"] isEqual:@"singleFinger"] && ![group[@"mode"] isEqual:@"twoFingers"] && ![group[@"mode"] isEqual:@"tapsOnly"]) return NO;
    NSDictionary *validated = LCWorkspaceTapSyncGroup(group, existing.snapshot.windows);
    if (group.count && !validated.count) return NO;
    if ([validated isEqual:existing.snapshot.tapSyncGroup]) return YES;
    NSMutableDictionary *propertyList = existing.snapshot.propertyList.mutableCopy;
    propertyList[@"tapSync"] = validated;
    LCWindowWorkspace *snapshot = [[LCWindowWorkspace alloc] initWithPropertyList:propertyList];
    LCNamedWorkspace *updated = [[LCNamedWorkspace alloc] initWithIdentifier:existing.identifier name:existing.name snapshot:snapshot];
    if (!updated) return NO;
    NSMutableArray *entries = self.workspaces.mutableCopy;
    entries[[entries indexOfObjectIdenticalTo:existing]] = updated;
    _workspaces = entries.copy;
    [self persist];
    return YES;
}

- (BOOL)removeWorkspace:(NSString *)identifier {
    if (![self reload]) return NO;
    LCNamedWorkspace *entry = [self workspaceWithIdentifier:identifier];
    if (!identifier || !entry) return NO;
    NSMutableArray *entries = self.workspaces.mutableCopy;
    [entries removeObjectIdenticalTo:entry];
    _workspaces = entries.copy;
    [self persist];
    return YES;
}

- (void)persist {
    NSMutableArray *entries = [NSMutableArray array];
    for (LCNamedWorkspace *entry in self.workspaces) [entries addObject:entry.propertyList];
    [self.defaults setObject:@{@"version": @1, @"workspaces": entries.copy} forKey:@"LCWorkspaceLibrary"];
}
@end
