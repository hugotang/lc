#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The game draws its own search label after UIKit relinquishes the keyboard.
// Bind only the field the user opened and keep game state out of diagnostics.
@interface LCMonsterStrikeTextBinding : NSObject
@property(nonatomic, weak, readonly) UITextField *field;
@property(nonatomic, copy, readonly) NSDictionary *signature;
- (BOOL)validate;
- (BOOL)refreshRenderedText;
@end

@interface LCMonsterStrikeTextInput : NSObject
+ (void)didBeginEditing:(UIView *)field;
+ (void)observeEvent:(UIEvent *)event;
+ (void)discard;
// Fixed readiness token only; never exposes text, pointers, classes or paths.
+ (nullable NSString *)diagnosticState;
+ (nullable LCMonsterStrikeTextBinding *)bindingForWindow:(UIWindow *)window field:(nullable UITextField *)field;
@end

NS_ASSUME_NONNULL_END
