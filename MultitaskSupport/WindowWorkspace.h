#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCWorkspaceWindow : NSObject
@property(nonatomic, copy, readonly) NSString *bundleName;
@property(nonatomic, copy, readonly) NSString *dataUUID;
@property(nonatomic, readonly) double scale;
@property(nonatomic, copy, readonly) NSDictionary *propertyList;
- (nullable instancetype)initWithBundleName:(NSString *)bundleName dataUUID:(NSString *)dataUUID scale:(double)scale;
@end

// A versioned, validated property list. It contains identifiers, not app data or credentials.
@interface LCWindowWorkspace : NSObject
@property(nonatomic, copy, readonly) NSArray<LCWorkspaceWindow *> *windows;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSNumber *> *> *> *proportions;
@property(nonatomic, readonly) BOOL singleRowInLandscape;
@property(nonatomic, readonly) BOOL reservePortraitTop;
@property(nonatomic, readonly) BOOL reservePortraitBottom;
// Only the source/target container identifiers are saved; restoring never enables input forwarding.
@property(nonatomic, copy, readonly) NSDictionary *tapSyncGroup;
@property(nonatomic, copy, readonly) NSDictionary *propertyList;
- (nullable instancetype)initWithPropertyList:(nullable id)propertyList;
- (nullable instancetype)initWithWindows:(NSArray<LCWorkspaceWindow *> *)windows proportions:(NSDictionary *)proportions
                   singleRowInLandscape:(BOOL)singleRowInLandscape;
- (nullable instancetype)initWithWindows:(NSArray<LCWorkspaceWindow *> *)windows proportions:(NSDictionary *)proportions
                   singleRowInLandscape:(BOOL)singleRowInLandscape reservePortraitTop:(BOOL)reservePortraitTop
                  reservePortraitBottom:(BOOL)reservePortraitBottom;
@end

@interface LCNamedWorkspace : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, strong, readonly) LCWindowWorkspace *snapshot;
@end

typedef NS_ENUM(NSInteger, LCWorkspaceLayoutPreference) {
    LCWorkspaceLayoutPreferenceSingleRowInLandscape,
    LCWorkspaceLayoutPreferenceReservePortraitTop,
    LCWorkspaceLayoutPreferenceReservePortraitBottom,
};

// Newest saved first. Renaming and preference edits preserve identity and ordering.
@interface LCWorkspaceLibrary : NSObject
@property(nonatomic, copy, readonly) NSArray<LCNamedWorkspace *> *workspaces;
- (nullable instancetype)initWithDefaults:(NSUserDefaults *)defaults legacyName:(NSString *)legacyName;
- (BOOL)reload;
- (nullable LCNamedWorkspace *)workspaceWithIdentifier:(nullable NSString *)identifier NS_SWIFT_NAME(workspace(identifier:));
- (BOOL)canUseName:(NSString *)name excludingIdentifier:(nullable NSString *)identifier NS_SWIFT_NAME(canUseName(_:excluding:));
- (nullable LCNamedWorkspace *)saveWorkspace:(LCWindowWorkspace *)snapshot name:(NSString *)name
                       replacingIdentifier:(nullable NSString *)identifier NS_SWIFT_NAME(save(_:name:replacing:));
- (BOOL)renameWorkspace:(NSString *)identifier name:(NSString *)name NS_SWIFT_NAME(rename(_:name:));
// Patch one saved preference without capturing live windows or changing library order.
- (BOOL)setLayoutPreference:(LCWorkspaceLayoutPreference)preference enabled:(BOOL)enabled
               forWorkspace:(NSString *)identifier NS_SWIFT_NAME(setLayoutPreference(_:enabled:for:));
- (BOOL)removeWorkspace:(NSString *)identifier NS_SWIFT_NAME(remove(_:));
@end

NS_ASSUME_NONNULL_END
