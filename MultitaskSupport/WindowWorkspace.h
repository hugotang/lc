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
@property(nonatomic, copy, readonly) NSDictionary *propertyList;
- (nullable instancetype)initWithPropertyList:(nullable id)propertyList;
- (nullable instancetype)initWithWindows:(NSArray<LCWorkspaceWindow *> *)windows proportions:(NSDictionary *)proportions;
@end

NS_ASSUME_NONNULL_END
