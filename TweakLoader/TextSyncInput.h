#import <UIKit/UIKit.h>
#import "../MultitaskSupport/TextSyncPacket.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCTextSyncInputResult) {
    LCTextSyncInputResultReady = 0,
    LCTextSyncInputResultUnavailable,
    LCTextSyncInputResultMismatch,
    LCTextSyncInputResultInvalid,
    LCTextSyncInputResultExpired,
};

typedef NS_ENUM(NSInteger, LCTextSyncUnavailableReason) {
    LCTextSyncUnavailableReasonNone = 0,
    LCTextSyncUnavailableReasonNoFocusedInput,
    LCTextSyncUnavailableReasonUnsupportedResponder,
    LCTextSyncUnavailableReasonAmbiguousInput,
    LCTextSyncUnavailableReasonNotVisible,
    LCTextSyncUnavailableReasonDisabled,
    LCTextSyncUnavailableReasonSecure,
    LCTextSyncUnavailableReasonComposing,
    LCTextSyncUnavailableReasonInvalidSelection,
    LCTextSyncUnavailableReasonInvalidText,
    LCTextSyncUnavailableReasonUnsupportedHierarchy,
    LCTextSyncUnavailableReasonFocusChanged,
    LCTextSyncUnavailableReasonWrongThread,
    LCTextSyncUnavailableReasonSessionChanged,
};

// Bounded diagnostics only: never includes field text, labels, IDs or class names.
FOUNDATION_EXPORT NSString *LCTextSyncUnavailableReasonName(LCTextSyncUnavailableReason reason);

// Main-thread, session-owned adapter. It never changes focus or retains text on disk.
@interface LCTextSyncInput : NSObject
@property(nonatomic, weak, readonly) UIView<UITextInput> *responder;
@property(nonatomic, readonly) LCTextSyncUnavailableReason lastUnavailableReason;
// The session owner invalidates replay when guest callbacks stop or replace it.
@property(nonatomic, copy, nullable) BOOL (^shouldContinue)(void);
+ (nullable instancetype)inputForWindow:(UIWindow *)window;
+ (nullable instancetype)inputForWindow:(UIWindow *)window unavailableReason:(LCTextSyncUnavailableReason * _Nullable)reason;
// Sources require focus. Followers can bind one unambiguous visible editable
// field after the keyboard moves to another account, without acquiring focus.
+ (nullable instancetype)inputForWindow:(UIWindow *)window source:(BOOL)source unavailableReason:(LCTextSyncUnavailableReason * _Nullable)reason;
// Allows an in-progress composition; does not advance the committed baseline.
- (LCTextSyncInputResult)validateCurrentInput;
// Ready with nil means unchanged text or an IME composition still in progress.
- (nullable NSDictionary *)captureEditAtTime:(NSTimeInterval)time result:(LCTextSyncInputResult *)result;
- (LCTextSyncInputResult)applyPacket:(NSDictionary *)packet;
@end

NS_ASSUME_NONNULL_END
