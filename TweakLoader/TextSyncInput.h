#import <UIKit/UIKit.h>
#import "../MultitaskSupport/TextSyncPacket.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCTextSyncInputResult) {
    LCTextSyncInputResultReady = 0,
    LCTextSyncInputResultUnavailable,
    LCTextSyncInputResultMismatch,
    LCTextSyncInputResultInvalid,
};

// Main-thread, session-owned adapter. It never changes focus or retains text on disk.
@interface LCTextSyncInput : NSObject
@property(nonatomic, weak, readonly) UIView<UITextInput> *responder;
+ (nullable instancetype)inputForWindow:(UIWindow *)window;
// Allows an in-progress composition; does not advance the committed baseline.
- (LCTextSyncInputResult)validateCurrentInput;
// Ready with nil means unchanged text or an IME composition still in progress.
- (nullable NSDictionary *)captureEditAtTime:(NSTimeInterval)time result:(LCTextSyncInputResult *)result;
- (LCTextSyncInputResult)applyPacket:(NSDictionary *)packet;
@end

NS_ASSUME_NONNULL_END
