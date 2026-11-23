#import <Foundation/Foundation.h>
#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Only account identifiers and mode are saved. Sessions, contacts and input are never serialized.
@interface LCTapSyncSelection : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *source;
@property(nonatomic, copy, readonly) NSArray<NSString *> *targets;
@property(nonatomic, readonly) LCTapSyncMode mode;
- (instancetype)initWithSource:(nullable NSString *)source targets:(NSArray<NSString *> *)targets mode:(LCTapSyncMode)mode;
- (instancetype)initWithGroupPropertyList:(nullable id)propertyList;
// Workspace groups require followers; last settings also preserve a source-only choice.
@property(nonatomic, copy, readonly) NSDictionary *groupPropertyList;
@end

@interface LCTapSyncSelectionStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (LCTapSyncSelection *)loadSelection;
- (void)saveSelection:(LCTapSyncSelection *)selection;
@end

NS_ASSUME_NONNULL_END
