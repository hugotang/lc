#import "TapSyncSelection.h"

static NSString *const LCTapSyncLastSelectionKey = @"LCTapSyncLastSelection";
static NSString *const LCTapSyncModeKey = @"LCTapSyncMode";

static BOOL LCTapSyncContainerIsValid(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 1024 &&
        ![value isEqual:@"."] && ![value isEqual:@".."] && ![value containsString:@"/"] &&
        ![value containsString:@"\\"] && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static LCTapSyncMode LCTapSyncValidMode(LCTapSyncMode mode) {
    return mode == LCTapSyncModeSingleFinger || mode == LCTapSyncModeTwoFingers ? mode : LCTapSyncModeTapsOnly;
}

static NSString *LCTapSyncModeName(LCTapSyncMode mode) {
    switch (mode) {
        case LCTapSyncModeSingleFinger: return @"singleFinger";
        case LCTapSyncModeTwoFingers: return @"twoFingers";
        default: return @"tapsOnly";
    }
}

@implementation LCTapSyncSelection
- (instancetype)initWithSource:(NSString *)source targets:(NSArray<NSString *> *)targets mode:(LCTapSyncMode)mode {
    if ((self = [super init])) {
        _mode = LCTapSyncValidMode(mode);
        _source = LCTapSyncContainerIsValid(source) ? source.copy : nil;
        NSMutableOrderedSet<NSString *> *unique = [NSMutableOrderedSet orderedSet];
        if (_source && [targets isKindOfClass:NSArray.class] && targets.count <= 63) {
            for (id target in targets) {
                if (!LCTapSyncContainerIsValid(target)) { [unique removeAllObjects]; break; }
                if (![target isEqual:_source]) [unique addObject:[target copy]];
            }
        }
        _targets = unique.array;
    }
    return self;
}
- (instancetype)initWithGroupPropertyList:(id)propertyList {
    NSDictionary *group = [propertyList isKindOfClass:NSDictionary.class] ? propertyList : @{};
    LCTapSyncMode mode = [group[@"mode"] isEqual:@"twoFingers"] ? LCTapSyncModeTwoFingers :
        [group[@"mode"] isEqual:@"singleFinger"] ? LCTapSyncModeSingleFinger : LCTapSyncModeTapsOnly;
    return [self initWithSource:group[@"source"] targets:group[@"targets"] ?: @[] mode:mode];
}
- (NSDictionary *)groupPropertyList {
    if (!self.source || !self.targets.count) return @{};
    NSMutableDictionary *group = [@{@"source": self.source, @"targets": self.targets} mutableCopy];
    if (self.mode != LCTapSyncModeTapsOnly) group[@"mode"] = LCTapSyncModeName(self.mode);
    return group.copy;
}
@end

@interface LCTapSyncSelectionStore ()
@property(nonatomic) NSUserDefaults *defaults;
@end

@implementation LCTapSyncSelectionStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}
- (LCTapSyncSelection *)loadSelection {
    id saved = [self.defaults objectForKey:LCTapSyncLastSelectionKey];
    if ([saved isKindOfClass:NSDictionary.class] && [saved[@"version"] isEqual:@1]) {
        return [[LCTapSyncSelection alloc] initWithGroupPropertyList:saved];
    }
    // Upgrade from the old mode-only preference without creating an active group.
    id legacy = [self.defaults objectForKey:LCTapSyncModeKey];
    LCTapSyncMode mode = LCTapSyncModeTapsOnly;
    if ([legacy isKindOfClass:NSNumber.class] && ([legacy isEqual:@(LCTapSyncModeSingleFinger)] ||
                                                [legacy isEqual:@(LCTapSyncModeTwoFingers)])) mode = [legacy integerValue];
    return [[LCTapSyncSelection alloc] initWithSource:nil targets:@[] mode:mode];
}
- (void)saveSelection:(LCTapSyncSelection *)selection {
    NSMutableDictionary *saved = [@{@"version": @1, @"targets": selection.targets,
                                   @"mode": LCTapSyncModeName(selection.mode)} mutableCopy];
    if (selection.source) saved[@"source"] = selection.source;
    [self.defaults setObject:saved.copy forKey:LCTapSyncLastSelectionKey];
    [self.defaults setInteger:selection.mode forKey:LCTapSyncModeKey];
}
@end
