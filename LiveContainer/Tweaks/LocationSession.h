#import <UIKit/UIKit.h>
#import "../LCAppLocationSettings.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const LCLocationSessionDidChange;
FOUNDATION_EXPORT NSString *LCLocationLocalized(NSString *key);

// All session operations run on the main thread. Saved choices are separate
// from the bounded live snapshot used to notify other accounts once per second.
@interface LCLocationSession : NSObject
@property(nonatomic, readonly) NSString *bundlePath;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSDictionary *settings;
@property(nonatomic, readonly) NSDictionary *snapshot;
@property(nonatomic, readonly) NSArray<NSDictionary *> *favorites;
@property(nonatomic, readonly) BOOL moving;
@property(nonatomic, readonly) BOOL quickControlEnabled;
@property(nonatomic, readonly, nullable) NSString *error;
+ (instancetype)sessionForPath:(NSString *)path title:(NSString *)title NS_SWIFT_NAME(session(path:title:));
- (void)refresh;
- (BOOL)selectPoint:(NSDictionary *)point enabled:(BOOL)enabled NS_SWIFT_NAME(select(point:enabled:));
- (BOOL)setLocationEnabled:(BOOL)enabled NS_SWIFT_NAME(setEnabled(_:));
- (BOOL)setQuickControlEnabled:(BOOL)enabled NS_SWIFT_NAME(setQuickControl(_:));
- (void)addFavorite;
- (void)removeFavoriteAtIndex:(NSUInteger)index NS_SWIFT_NAME(removeFavorite(at:));
- (void)moveEast:(double)east north:(double)north speed:(double)speed NS_SWIFT_NAME(move(east:north:speed:));
- (void)stopMoving;
@end

FOUNDATION_EXPORT void LCLocationStartGuest(NSString *bundlePath, NSString *title, BOOL guestControls);
NS_ASSUME_NONNULL_END
