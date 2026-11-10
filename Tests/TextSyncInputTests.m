#import <XCTest/XCTest.h>
#import "../TweakLoader/TextSyncInput.h"
#import "../TweakLoader/MonsterStrikeTextInput.h"
#import "TapSyncTestWindow.h"
#import <objc/runtime.h>

@interface LCTextSyncNestedResponderView : UIView
@end
@implementation LCTextSyncNestedResponderView
- (BOOL)isFirstResponder { return YES; }
@end

@interface LCTextSyncAdditionalFocusedField : UITextField
@end
@implementation LCTextSyncAdditionalFocusedField
- (BOOL)isFirstResponder { return YES; }
@end

@interface LCTextSyncMissingSelectionField : LCTextSyncAdditionalFocusedField
@end
@implementation LCTextSyncMissingSelectionField
- (UITextRange *)selectedTextRange { return nil; }
@end

@interface LCTextSyncPassiveField : UITextField
@property(nonatomic) NSUInteger focusRequests;
@end
@implementation LCTextSyncPassiveField
- (BOOL)becomeFirstResponder { self.focusRequests++; return [super becomeFirstResponder]; }
- (UITextRange *)selectedTextRange { return self.isFirstResponder ? [super selectedTextRange] : nil; }
@end

@interface LCTextSyncCallbackField : LCTextSyncPassiveField
@property(nonatomic, copy) void (^onReplace)(void);
@property(nonatomic) BOOL suppressUIKitCallbacks;
@end
@implementation LCTextSyncCallbackField
- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (self.suppressUIKitCallbacks) {
        NSInteger start = [self offsetFromPosition:self.beginningOfDocument toPosition:range.start];
        NSInteger end = [self offsetFromPosition:self.beginningOfDocument toPosition:range.end];
        self.text = [self.text stringByReplacingCharactersInRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start)) withString:text];
    } else [super replaceRange:range withText:text];
    if (self.onReplace) self.onReplace();
}
@end

@interface LCTextSyncTestDelegate : NSObject <UITextFieldDelegate, UITextViewDelegate>
@property(nonatomic) NSUInteger validations, changes, controls;
@property(nonatomic) BOOL reject, transform;
@property(nonatomic) NSTimeInterval validationDelay;
@property(nonatomic, copy) void (^onValidate)(void);
@property(nonatomic, copy) void (^onControl)(void);
@property(nonatomic) BOOL hideAfterEditing, removeAfterEditing;
@end
@implementation LCTextSyncTestDelegate
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    self.validations++;
    if (self.validationDelay > 0) [NSThread sleepForTimeInterval:self.validationDelay];
    if (self.onValidate) self.onValidate();
    return !self.reject;
}
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    self.validations++;
    if (self.validationDelay > 0) [NSThread sleepForTimeInterval:self.validationDelay];
    if (self.onValidate) self.onValidate();
    return !self.reject;
}
- (void)textViewDidChange:(UITextView *)textView {
    self.changes++;
    if (self.transform) textView.text = @"Changed by app";
}
- (void)editingChanged:(UITextField *)field {
    self.controls++;
    if (self.transform) field.text = @"Changed by app";
    if (self.onControl) self.onControl();
}
- (void)textFieldDidEndEditing:(UITextField *)field {
    if (self.hideAfterEditing) field.hidden = YES;
    if (self.removeAfterEditing) [field removeFromSuperview];
}
@end

// Adapter integration fixture. The bridge's binary/version and engine graph
// checks have separate tests; this exercises the real UIKit replay pipeline.
@interface LCTextSyncGameBindingFixture : LCMonsterStrikeTextBinding
@property(nonatomic, weak) UITextField *testField;
@property(nonatomic, weak) UIWindow *testWindow;
@property(nonatomic, weak) id testOwner;
@property(nonatomic, copy) NSDictionary *testSignature;
@property(nonatomic, copy) NSString *renderedText;
@property(nonatomic, copy) void (^onRefresh)(void);
@property(nonatomic) BOOL valid;
@property(nonatomic) BOOL requiresOwner;
@property(nonatomic) NSUInteger refreshes;
@end
@implementation LCTextSyncGameBindingFixture
- (UITextField *)field { return self.testField; }
- (NSDictionary *)signature { return self.testSignature; }
- (BOOL)validate {
    id owner = self.testOwner;
    return self.valid && self.testField && self.testWindow &&
        (!self.requiresOwner || (owner && LCTextSyncOriginalDelegate(self.testField) == owner));
}
- (BOOL)refreshRenderedText {
    if (![self validate]) return NO;
    self.refreshes++;
    self.renderedText = self.testField.text;
    if (self.onRefresh) self.onRefresh();
    return [self validate];
}
@end

static NSMutableArray<LCTextSyncGameBindingFixture *> *LCTextSyncGameFixtures;
static IMP LCTextSyncOriginalBindingResolver;
static LCMonsterStrikeTextBinding *LCTextSyncFixtureBinding(id receiver, SEL selector, UIWindow *window, UITextField *field) {
    for (LCTextSyncGameBindingFixture *binding in LCTextSyncGameFixtures) {
        if (binding.testWindow == window && (!field || binding.testField == field) && [binding validate]) return binding;
    }
    return nil;
}

@interface TextSyncInputTests : XCTestCase
@property(nonatomic) UIView *surface;
@property(nonatomic) UITextField *field;
@property(nonatomic) UITextView *textView;
@property(nonatomic) UIWindow *window;
@end

@implementation TextSyncInputTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.window = LCTapSyncTestHostWindow();
    XCTAssertNotNil(self.window);
    self.surface = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 260)];
    [self.window.rootViewController.view addSubview:self.surface];
    self.field = [[UITextField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
    self.field.accessibilityIdentifier = @"text-sync-test-field";
    self.field.text = @"";
    self.field.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    [self.surface addSubview:self.field];
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(10, 80, 260, 120)];
    self.textView.accessibilityIdentifier = @"text-sync-test-view";
    self.textView.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    [self.surface addSubview:self.textView];
    [self.window makeKeyWindow];
    XCTAssertTrue([self.field becomeFirstResponder]);
    [self setSelection:NSMakeRange(0, 0) input:self.field];
}
- (void)tearDown {
    if (LCTextSyncOriginalBindingResolver) {
        method_setImplementation(class_getClassMethod(LCMonsterStrikeTextInput.class, @selector(bindingForWindow:field:)), LCTextSyncOriginalBindingResolver);
        LCTextSyncOriginalBindingResolver = NULL;
        LCTextSyncGameFixtures = nil;
    }
    [self.window endEditing:YES];
    [self.surface removeFromSuperview];
    self.surface = nil;
    self.field = nil;
    self.textView = nil;
    self.window = nil;
    [super tearDown];
}
- (LCTextSyncGameBindingFixture *)bindGameField:(UITextField *)field window:(UIWindow *)window owner:(id)owner {
    if (!LCTextSyncOriginalBindingResolver) {
        LCTextSyncGameFixtures = [NSMutableArray array];
        LCTextSyncOriginalBindingResolver = method_setImplementation(class_getClassMethod(LCMonsterStrikeTextInput.class, @selector(bindingForWindow:field:)), (IMP)LCTextSyncFixtureBinding);
    }
    LCTextSyncGameBindingFixture *binding = [LCTextSyncGameBindingFixture new];
    binding.testField = field;
    binding.testWindow = window;
    binding.testOwner = owner;
    binding.requiresOwner = owner != nil;
    binding.testSignature = @{@"kind": @"field", @"path": @[@1, @2], @"identifier": @"monster-strike-test-search"};
    binding.renderedText = field.text;
    binding.valid = YES;
    [LCTextSyncGameFixtures addObject:binding];
    return binding;
}
- (void)setSelection:(NSRange)selection input:(UIView<UITextInput> *)input {
    UITextPosition *start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)selection.location];
    UITextPosition *end = [input positionFromPosition:start offset:(NSInteger)selection.length];
    XCTAssertNotNil(start);
    XCTAssertNotNil(end);
    input.selectedTextRange = [input textRangeFromPosition:start toPosition:end];
}
- (NSDictionary *)packetFrom:(NSString *)before to:(NSString *)after input:(UIView<UITextInput> *)input {
    if ([input isKindOfClass:UITextField.class]) ((UITextField *)input).text = before;
    else ((UITextView *)input).text = before;
    [self setSelection:NSMakeRange(before.length, 0) input:input];
    LCTextSyncInput *source = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertNotNil(source);
    if ([input isKindOfClass:UITextField.class]) ((UITextField *)input).text = after;
    else ((UITextView *)input).text = after;
    [self setSelection:NSMakeRange(after.length, 0) input:input];
    LCTextSyncInputResult result = LCTextSyncInputResultInvalid;
    NSDictionary *packet = [source captureEditAtTime:NSProcessInfo.processInfo.systemUptime result:&result];
    XCTAssertEqual(result, LCTextSyncInputResultReady);
    XCTAssertTrue(LCTextSyncPacketIsValid(packet));
    return packet;
}
- (void)testCaptureAdvancesOnceAndRetainsUnicodeSelection {
    LCTextSyncInput *source = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertNotNil(source);
    self.field.text = @"房間😀12";
    [self setSelection:NSMakeRange(4, 2) input:self.field];
    LCTextSyncInputResult result;
    NSDictionary *packet = [source captureEditAtTime:10 result:&result];
    XCTAssertEqual(result, LCTextSyncInputResultReady);
    XCTAssertEqualObjects(packet[@"before"], @"");
    XCTAssertEqualObjects(packet[@"after"], @"房間😀12");
    XCTAssertEqualObjects(packet[@"selectionLocation"], @4);
    XCTAssertEqualObjects(packet[@"selectionLength"], @2);
    XCTAssertNil([source captureEditAtTime:10.1 result:&result]);
    self.field.text = @"房間😀";
    [self setSelection:NSMakeRange(4, 0) input:self.field];
    packet = [source captureEditAtTime:10.2 result:&result];
    XCTAssertEqualObjects(packet[@"before"], @"房間😀12");
    XCTAssertEqualObjects(packet[@"after"], @"房間😀");
}
- (void)testCompositionWaitsForCommitAndCancellationProducesNoPacket {
    LCTextSyncInput *source = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertNotNil(source);
    [self.field setMarkedText:@"zhong" selectedRange:NSMakeRange(5, 0)];
    XCTAssertNotNil(self.field.markedTextRange);
    LCTextSyncInputResult result;
    XCTAssertNil([source captureEditAtTime:10 result:&result]);
    XCTAssertEqual(result, LCTextSyncInputResultReady);
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window]);
    [self.field setMarkedText:@"中" selectedRange:NSMakeRange(1, 0)];
    XCTAssertNil([source captureEditAtTime:10.1 result:&result]);
    [self.field unmarkText];
    NSDictionary *packet = [source captureEditAtTime:10.2 result:&result];
    XCTAssertEqualObjects(packet[@"before"], @"");
    XCTAssertEqualObjects(packet[@"after"], @"中");
    [self.field setMarkedText:@"x" selectedRange:NSMakeRange(1, 0)];
    XCTAssertNil([source captureEditAtTime:10.3 result:&result]);
    [self.field setMarkedText:@"" selectedRange:NSMakeRange(0, 0)];
    [self.field unmarkText];
    XCTAssertEqualObjects(self.field.text, @"中");
    XCTAssertNil([source captureEditAtTime:10.4 result:&result]);
}
- (void)testFieldReplayDeliversDelegateControlAndNotificationExactlyOnce {
    NSDictionary *packet = [self packetFrom:@"123" to:@"12😀3" input:self.field];
    self.field.text = @"123";
    [self setSelection:NSMakeRange(0, 0) input:self.field];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.field.delegate = delegate;
    [self.field addTarget:delegate action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    __block NSUInteger notifications = 0;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:UITextFieldTextDidChangeNotification object:self.field queue:nil usingBlock:^(NSNotification *note) { notifications++; }];
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultReady);
    [NSNotificationCenter.defaultCenter removeObserver:token];
    XCTAssertEqualObjects(self.field.text, @"12😀3");
    XCTAssertEqual(delegate.validations, 1u);
    XCTAssertEqual(delegate.controls, 1u);
    XCTAssertEqual(notifications, 1u);
    XCTAssertEqual(self.field.delegate, delegate);
    XCTAssertEqual([self.field offsetFromPosition:self.field.beginningOfDocument toPosition:self.field.selectedTextRange.start], 5);
    LCTextSyncInputResult result;
    XCTAssertNil([target captureEditAtTime:11 result:&result]);
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
}
- (void)testTextViewReplayHandlesMultilinePasteAndDeletion {
    XCTAssertTrue([self.textView becomeFirstResponder]);
    NSDictionary *packet = [self packetFrom:@"first\nsecond" to:@"first\n中文👩🏽‍💻\nsecond" input:self.textView];
    self.textView.text = @"first\nsecond";
    [self setSelection:NSMakeRange(0, 0) input:self.textView];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.textView.delegate = delegate;
    __block NSUInteger notifications = 0;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:UITextViewTextDidChangeNotification object:self.textView queue:nil usingBlock:^(NSNotification *note) { notifications++; }];
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultReady);
    [NSNotificationCenter.defaultCenter removeObserver:token];
    XCTAssertEqualObjects(self.textView.text, packet[@"after"]);
    XCTAssertEqual(delegate.validations, 1u);
    XCTAssertEqual(delegate.changes, 1u);
    XCTAssertEqual(notifications, 1u);
    NSDictionary *deletion = [self packetFrom:self.textView.text to:@"" input:self.textView];
    self.textView.text = deletion[@"before"];
    [self setSelection:NSMakeRange(self.textView.text.length, 0) input:self.textView];
    target = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertEqual([target applyPacket:deletion], LCTextSyncInputResultReady);
    XCTAssertEqualObjects(self.textView.text, @"");
}
- (void)testReplayHonorsDelegateVetoAndDetectsAppTransformation {
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self setSelection:NSMakeRange(1, 0) input:self.field];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.field.delegate = delegate;
    delegate.reject = YES;
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
    XCTAssertEqualObjects(self.field.text, @"A");
    delegate.reject = NO;
    delegate.transform = YES;
    [self.field addTarget:delegate action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
    XCTAssertEqualObjects(self.field.text, @"Changed by app");
    XCTAssertEqual(self.field.delegate, delegate);
}
- (void)testAccentAndJoinedEmojiChangesReplayWholeComposedCharacters {
    for (NSArray<NSString *> *pair in @[@[@"e", @"e\u0301"], @[@"👩🏽‍💻", @"👩🏻‍💻"], @[@"🇭🇰", @"🇯🇵"]]) {
        NSDictionary *packet = [self packetFrom:pair[0] to:pair[1] input:self.field];
        self.field.text = pair[0];
        [self setSelection:NSMakeRange(pair[0].length, 0) input:self.field];
        LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
        XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultReady);
        XCTAssertEqualObjects(self.field.text, pair[1]);
    }
}
- (void)testFocusSecurityWindowAndFieldSignatureChangesReject {
    LCTextSyncInput *source = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertNotNil(source);
    self.field.secureTextEntry = YES;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window]);
    XCTAssertEqual([source validateCurrentInput], LCTextSyncInputResultUnavailable);
    self.field.secureTextEntry = NO;
    self.field.accessibilityIdentifier = @"another-field";
    XCTAssertEqual([source validateCurrentInput], LCTextSyncInputResultMismatch);
    self.field.accessibilityIdentifier = @"text-sync-test-field";
    XCTAssertTrue([self.textView becomeFirstResponder]);
    XCTAssertEqual([source validateCurrentInput], LCTextSyncInputResultUnavailable);
    [self.window endEditing:YES];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window]);
    XCTAssertTrue([self.field becomeFirstResponder]);
    [self.field removeFromSuperview];
    XCTAssertEqual([source validateCurrentInput], LCTextSyncInputResultUnavailable);
}
- (void)testMismatchCompositionAndProgrammaticTargetEditsNeverOverwrite {
    NSDictionary *packet = [self packetFrom:@"before" to:@"after" input:self.field];
    self.field.text = @"before";
    [self setSelection:NSMakeRange(6, 0) input:self.field];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    self.field.text = @"unrelated";
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
    XCTAssertEqualObjects(self.field.text, @"unrelated");
    self.field.text = @"before";
    [self setSelection:NSMakeRange(6, 0) input:self.field];
    [self.field setMarkedText:@"x" selectedRange:NSMakeRange(1, 0)];
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonComposing);
    [self.field unmarkText];
    self.field.text = @"before";
    [self setSelection:NSMakeRange(6, 0) input:self.field];
    NSMutableDictionary *wrong = packet.mutableCopy;
    NSMutableDictionary *signature = [wrong[@"field"] mutableCopy];
    signature[@"identifier"] = @"another-field";
    wrong[@"field"] = signature;
    XCTAssertEqual([target applyPacket:wrong], LCTextSyncInputResultMismatch);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonNone);
    XCTAssertEqualObjects(self.field.text, @"before");
}
- (void)testPacketValidationBoundsUnicodeAndFreshness {
    NSDictionary *packet = [self packetFrom:@"" to:@"😀" input:self.field];
    NSTimeInterval timestamp = [packet[@"timestamp"] doubleValue];
    XCTAssertTrue(LCTextSyncPacketIsFresh(packet, timestamp + 0.75));
    XCTAssertFalse(LCTextSyncPacketIsFresh(packet, timestamp + 0.751));
    XCTAssertFalse(LCTextSyncPacketIsFresh(packet, timestamp - 0.01));
    XCTAssertFalse(LCTextSyncPacketIsFresh(packet, NAN));
    NSMutableDictionary *bad = packet.mutableCopy;
    bad[@"selectionLocation"] = @1;
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"selectionLength"] = @1;
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"selectionLength"] = @(-1);
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"timestamp"] = @(NAN);
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"extra"] = @YES;
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"after"] = [@"x" stringByPaddingToLength:4097 withString:@"x" startingAtIndex:0];
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    unichar invalid = 0xD800;
    bad = packet.mutableCopy; bad[@"after"] = [NSString stringWithCharacters:&invalid length:1];
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"field"] = @{@"kind": @"field", @"path": @[@4096], @"identifier": @""};
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
    bad = packet.mutableCopy; bad[@"field"] = @{@"kind": @"field", @"path": @[@0.5], @"identifier": @""};
    XCTAssertFalse(LCTextSyncPacketIsValid(bad));
}
- (void)testExpiredPacketAndSlowDelegateNeverMutateTarget {
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self setSelection:NSMakeRange(1, 0) input:self.field];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.field.delegate = delegate;
    [self.field addTarget:delegate action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    NSMutableDictionary *expired = packet.mutableCopy;
    expired[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime - 1);
    XCTAssertEqual([target applyPacket:expired], LCTextSyncInputResultExpired);
    XCTAssertEqualObjects(self.field.text, @"A");
    XCTAssertEqual(delegate.validations, 0u);
    XCTAssertEqual(delegate.controls, 0u);
    NSMutableDictionary *fresh = packet.mutableCopy;
    fresh[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    delegate.validationDelay = 0.8;
    XCTAssertEqual([target applyPacket:fresh], LCTextSyncInputResultExpired);
    XCTAssertEqualObjects(self.field.text, @"A");
    XCTAssertEqual(delegate.validations, 1u);
    XCTAssertEqual(delegate.controls, 0u);
    XCTAssertEqual(self.field.delegate, delegate);
}
- (void)testDelegateInvalidatingSessionCannotApplyApprovedEdit {
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self setSelection:NSMakeRange(1, 0) input:self.field];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window];
    __block BOOL currentSession = YES;
    target.shouldContinue = ^BOOL { return currentSession; };
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    delegate.onValidate = ^{ currentSession = NO; };
    self.field.delegate = delegate;
    [self.field addTarget:delegate action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
    XCTAssertEqualObjects(self.field.text, @"A");
    XCTAssertEqual(delegate.validations, 1u);
    XCTAssertEqual(delegate.controls, 0u);
    XCTAssertEqual(self.field.delegate, delegate);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonSessionChanged);
}
- (void)testPrivateEditorIsPartOfFocusedFieldButSeparateFocusedFieldsAreRejected {
    XCTAssertTrue(self.field.isFirstResponder);
    LCTextSyncNestedResponderView *editor = [[LCTextSyncNestedResponderView alloc] initWithFrame:self.field.bounds];
    [self.field addSubview:editor];
    LCTextSyncInput *input = [LCTextSyncInput inputForWindow:self.window];
    XCTAssertNotNil(input);
    XCTAssertEqual(input.responder, self.field);
    LCTextSyncAdditionalFocusedField *other = [[LCTextSyncAdditionalFocusedField alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:other];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window]);
    XCTAssertEqual([input validateCurrentInput], LCTextSyncInputResultUnavailable);
    [other removeFromSuperview];
    XCTAssertEqual([input validateCurrentInput], LCTextSyncInputResultReady);
    [editor removeFromSuperview];
}
- (void)testReadinessReasonsDistinguishFocusCompositionAndSecurity {
    LCTextSyncUnavailableReason reason = LCTextSyncUnavailableReasonNoFocusedInput;
    LCTextSyncInput *input = [LCTextSyncInput inputForWindow:self.window unavailableReason:&reason];
    XCTAssertNotNil(input);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNone);
    self.field.secureTextEntry = YES;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonSecure);
    XCTAssertEqual([input validateCurrentInput], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(input.lastUnavailableReason, LCTextSyncUnavailableReasonSecure);
    self.field.secureTextEntry = NO;
    [self.field setMarkedText:@"mi" selectedRange:NSMakeRange(2, 0)];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonComposing);
    // Ongoing source composition remains allowed after a successful preparation.
    XCTAssertEqual([input validateCurrentInput], LCTextSyncInputResultReady);
    XCTAssertEqual(input.lastUnavailableReason, LCTextSyncUnavailableReasonNone);
    [self.field unmarkText];
    [self.window endEditing:YES];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNoFocusedInput);
    XCTAssertEqual([input validateCurrentInput], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(input.lastUnavailableReason, LCTextSyncUnavailableReasonFocusChanged);
}
- (void)testReadinessReasonsDistinguishUnsupportedAmbiguousAndInvisibleResponders {
    [self.window endEditing:YES];
    LCTextSyncUnavailableReason reason;
    LCTextSyncNestedResponderView *unsupported = [[LCTextSyncNestedResponderView alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:unsupported];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonUnsupportedResponder);
    [unsupported removeFromSuperview];
    LCTextSyncAdditionalFocusedField *proxy = [[LCTextSyncAdditionalFocusedField alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:proxy];
    proxy.alpha = 0;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNotVisible);
    proxy.alpha = 1;
    proxy.enabled = NO;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonDisabled);
    proxy.enabled = YES;
    XCTAssertTrue([self.field becomeFirstResponder]);
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonAmbiguousInput);
    [proxy removeFromSuperview];
}
- (void)testReadinessReasonsDistinguishSelectionTextAndStructureWithoutIncludingValues {
    LCTextSyncUnavailableReason reason;
    NSString *secret = @"private player field and text";
    self.field.text = [secret stringByPaddingToLength:4097 withString:secret startingAtIndex:0];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonInvalidText);
    XCTAssertEqualObjects(LCTextSyncUnavailableReasonName(reason), @"invalidText");
    self.field.text = @"";
    [self setSelection:NSMakeRange(0, 0) input:self.field];
    self.field.accessibilityIdentifier = [secret stringByPaddingToLength:1025 withString:secret startingAtIndex:0];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonUnsupportedHierarchy);
    [self.window endEditing:YES];
    LCTextSyncMissingSelectionField *missing = [[LCTextSyncMissingSelectionField alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:missing];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonInvalidSelection);
    [missing removeFromSuperview];
    NSArray *names = @[@"none", @"noFocusedInput", @"unsupportedResponder", @"ambiguousInput", @"notVisible", @"disabled", @"secure", @"composing", @"invalidSelection", @"invalidText", @"unsupportedHierarchy", @"focusChanged", @"wrongThread", @"sessionChanged"];
    for (NSInteger value = LCTextSyncUnavailableReasonNone; value <= LCTextSyncUnavailableReasonSessionChanged; value++) {
        NSString *name = LCTextSyncUnavailableReasonName((LCTextSyncUnavailableReason)value);
        XCTAssertEqualObjects(name, names[(NSUInteger)value]);
        XCTAssertFalse([name containsString:secret]);
        XCTAssertLessThan(name.length, 32u);
    }
    XCTAssertEqualObjects(LCTextSyncUnavailableReasonName((LCTextSyncUnavailableReason)NSIntegerMax), @"unknown");
}
- (void)testPassiveFieldReplaysAfterKeyboardTransfersWithoutTakingFocus {
    self.textView.hidden = YES;
    NSDictionary *packet = [self packetFrom:@"A" to:@"A中文😀" input:self.field];
    self.field.text = @"A";
    [self setSelection:NSMakeRange(1, 0) input:self.field];
    [self.field resignFirstResponder];
    XCTAssertFalse(self.field.isFirstResponder);
    LCTextSyncUnavailableReason reason;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:YES unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNoFocusedInput);
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason];
    XCTAssertNotNil(target);
    XCTAssertEqual(target.responder, self.field);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNone);

    UIWindow *keyboardOwner = [[UIWindow alloc] initWithWindowScene:self.window.windowScene];
    keyboardOwner.frame = self.window.bounds;
    keyboardOwner.rootViewController = [UIViewController new];
    UITextField *source = [[UITextField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
    source.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    [keyboardOwner.rootViewController.view addSubview:source];
    [keyboardOwner makeKeyAndVisible];
    XCTAssertTrue([source becomeFirstResponder]);
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.field.delegate = delegate;
    [self.field addTarget:delegate action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    __block NSUInteger notifications = 0;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:UITextFieldTextDidChangeNotification object:self.field queue:nil usingBlock:^(NSNotification *note) { notifications++; }];
    @try {
        NSMutableDictionary *fresh = packet.mutableCopy;
        fresh[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
        XCTAssertEqual([target applyPacket:fresh], LCTextSyncInputResultReady);
        XCTAssertEqualObjects(self.field.text, @"A中文😀");
        XCTAssertFalse(self.field.isFirstResponder);
        XCTAssertTrue(source.isFirstResponder);
        XCTAssertEqual(delegate.validations, 1u);
        XCTAssertEqual(delegate.controls, 1u);
        XCTAssertEqual(notifications, 1u);
        XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultReady);
    } @finally {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        [keyboardOwner endEditing:YES];
        keyboardOwner.hidden = YES;
        keyboardOwner.windowScene = nil;
        keyboardOwner.rootViewController = nil;
        [self.window makeKeyWindow];
    }
}
- (void)testPassiveTextViewReplaysMultilineEditAndDeletion {
    XCTAssertTrue([self.textView becomeFirstResponder]);
    self.field.hidden = YES;
    NSDictionary *packet = [self packetFrom:@"line" to:@"line\n下一行" input:self.textView];
    self.textView.text = @"line";
    [self.textView resignFirstResponder];
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    LCTextSyncTestDelegate *delegate = [LCTextSyncTestDelegate new];
    self.textView.delegate = delegate;
    NSMutableDictionary *fresh = packet.mutableCopy;
    fresh[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    XCTAssertEqual([target applyPacket:fresh], LCTextSyncInputResultReady);
    XCTAssertFalse(self.textView.isFirstResponder);
    XCTAssertEqualObjects(self.textView.text, @"line\n下一行");
    XCTAssertEqual(delegate.validations, 1u);
    XCTAssertEqual(delegate.changes, 1u);
    NSMutableDictionary *deletion = packet.mutableCopy;
    deletion[@"before"] = packet[@"after"];
    deletion[@"after"] = @"";
    deletion[@"selectionLocation"] = @0;
    deletion[@"selectionLength"] = @0;
    deletion[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    XCTAssertEqual([target applyPacket:deletion], LCTextSyncInputResultReady);
    XCTAssertEqualObjects(self.textView.text, @"");
    XCTAssertFalse(self.textView.isFirstResponder);
}
- (void)testPassiveFollowerDoesNotRequireOrSetOffFocusSelection {
    [self.window endEditing:YES];
    [self.field removeFromSuperview];
    self.field = [[LCTextSyncPassiveField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
    [self.surface insertSubview:self.field atIndex:0];
    self.textView.hidden = YES;
    self.field.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    XCTAssertTrue([self.field becomeFirstResponder]);
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self.field resignFirstResponder];
    LCTextSyncPassiveField *field = (LCTextSyncPassiveField *)self.field;
    field.focusRequests = 0;
    XCTAssertNil(field.selectedTextRange);
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    NSMutableDictionary *fresh = packet.mutableCopy;
    fresh[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    XCTAssertEqual([target applyPacket:fresh], LCTextSyncInputResultReady);
    XCTAssertEqualObjects(field.text, @"AB");
    XCTAssertFalse(field.isFirstResponder);
    XCTAssertEqual(field.focusRequests, 0u);
    // UIKit may update its internal selection during replacement. The adapter
    // does not require a publicly available off-focus caret or acquire focus.
    XCTAssertNil(field.selectedTextRange);
}
- (void)testPassiveFollowerRequiresUniqueEligibleInputAndRejectsCompetingFocus {
    [self.window endEditing:YES];
    LCTextSyncUnavailableReason reason;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonAmbiguousInput);
    self.textView.hidden = YES;
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason];
    XCTAssertNotNil(target);
    self.textView.hidden = NO;
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonAmbiguousInput);
    self.textView.hidden = YES;
    self.field.secureTextEntry = YES;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    self.field.secureTextEntry = NO;
    self.field.enabled = NO;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    self.field.enabled = YES;
    CGRect frame = self.field.frame;
    self.field.frame = CGRectZero;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    self.field.frame = frame;
    LCTextSyncNestedResponderView *other = [[LCTextSyncNestedResponderView alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:other];
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonUnsupportedResponder);
    [other removeFromSuperview];
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultReady);
    UIView *wrapper = [[UIView alloc] initWithFrame:self.surface.bounds];
    [self.surface addSubview:wrapper];
    [wrapper addSubview:self.field];
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultMismatch);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonUnsupportedHierarchy);
    [self.field removeFromSuperview];
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
}
- (void)testGameFieldsReplayAcrossFourWindowsAfterNativeFieldsHideOrDetach {
    self.textView.hidden = YES;
    LCTextSyncTestDelegate *sourceOwner = [LCTextSyncTestDelegate new];
    self.field.delegate = sourceOwner;
    [self bindGameField:self.field window:self.window owner:sourceOwner];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableArray<UITextField *> *fields = [NSMutableArray array];
    NSMutableArray<LCTextSyncTestDelegate *> *owners = [NSMutableArray array];
    NSMutableArray<LCTextSyncGameBindingFixture *> *bindings = [NSMutableArray array];
    NSMutableArray<LCTextSyncInput *> *followers = [NSMutableArray array];
    @try {
        for (NSUInteger i = 0; i < 3; i++) {
            UIWindow *window = [[UIWindow alloc] initWithWindowScene:self.window.windowScene];
            [windows addObject:window];
            window.frame = self.window.bounds;
            window.rootViewController = [UIViewController new];
            LCTextSyncPassiveField *field = [[LCTextSyncPassiveField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
            field.text = @"";
            field.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
            LCTextSyncTestDelegate *owner = [LCTextSyncTestDelegate new];
            owner.hideAfterEditing = YES;
            owner.removeAfterEditing = i == 1;
            field.delegate = owner;
            [field addTarget:owner action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
            [window.rootViewController.view addSubview:field];
            [window makeKeyAndVisible];
            XCTAssertTrue([field becomeFirstResponder]);
            [fields addObject:field];
            [owners addObject:owner];
            [bindings addObject:[self bindGameField:field window:window owner:owner]];
            XCTAssertTrue([field resignFirstResponder]);
            XCTAssertTrue(field.hidden);
            XCTAssertFalse(field.isFirstResponder);
        }
        [self.window makeKeyWindow];
        XCTAssertTrue([self.field becomeFirstResponder]);
        [self setSelection:NSMakeRange(0, 0) input:self.field];
        LCTextSyncInput *source = [LCTextSyncInput inputForWindow:self.window];
        XCTAssertNotNil(source);
        XCTAssertEqual(self.field.delegate, sourceOwner);
        for (NSUInteger i = 0; i < windows.count; i++) {
            LCTextSyncUnavailableReason reason;
            LCTextSyncInput *follower = [LCTextSyncInput inputForWindow:windows[i] source:NO unavailableReason:&reason];
            XCTAssertNotNil(follower);
            XCTAssertEqual(reason, LCTextSyncUnavailableReasonNone);
            [followers addObject:follower];
            ((LCTextSyncPassiveField *)fields[i]).focusRequests = 0;
        }
        for (NSString *text in @[@"搜尋", @"検索😀", @"検索", @""]) {
            self.field.text = text;
            [self setSelection:NSMakeRange(text.length, 0) input:self.field];
            LCTextSyncInputResult result;
            NSDictionary *packet = [source captureEditAtTime:NSProcessInfo.processInfo.systemUptime result:&result];
            XCTAssertEqual(result, LCTextSyncInputResultReady);
            XCTAssertNotNil(packet);
            for (NSUInteger i = 0; i < followers.count; i++) {
                XCTAssertEqual([followers[i] applyPacket:packet], LCTextSyncInputResultReady);
                XCTAssertEqualObjects(fields[i].text, text);
                XCTAssertEqualObjects(bindings[i].renderedText, text);
                XCTAssertTrue(fields[i].hidden);
                XCTAssertFalse(fields[i].isFirstResponder);
                XCTAssertEqual(((LCTextSyncPassiveField *)fields[i]).focusRequests, 0u);
                XCTAssertTrue(self.field.isFirstResponder);
            }
        }
        XCTAssertNil(fields[1].superview);
        for (NSUInteger i = 0; i < owners.count; i++) {
            XCTAssertEqual(owners[i].validations, 4u);
            XCTAssertEqual(owners[i].controls, 4u);
            XCTAssertEqual(bindings[i].refreshes, 4u);
        }
    } @finally {
        for (UIWindow *window in windows) {
            [window endEditing:YES];
            window.hidden = YES;
            window.windowScene = nil;
            window.rootViewController = nil;
        }
        [self.window makeKeyWindow];
    }
}
- (void)testGameBindingCannotBypassSourceFocusOrCompetingInputs {
    self.textView.hidden = YES;
    LCTextSyncGameBindingFixture *binding = [self bindGameField:self.field window:self.window owner:nil];
    [self.field resignFirstResponder];
    self.field.hidden = YES;
    LCTextSyncUnavailableReason reason;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:YES unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonNoFocusedInput);
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason];
    XCTAssertNotNil(target);
    self.textView.hidden = NO;
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
    LCTextSyncInput *other = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason];
    XCTAssertEqual(other.responder, self.textView);
    self.textView.hidden = YES;
    LCTextSyncNestedResponderView *unsupported = [[LCTextSyncNestedResponderView alloc] initWithFrame:CGRectMake(10, 210, 260, 44)];
    [self.surface addSubview:unsupported];
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonUnsupportedResponder);
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
    [unsupported removeFromSuperview];
    self.field.secureTextEntry = YES;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonSecure);
    self.field.secureTextEntry = NO;
    self.field.enabled = NO;
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
    XCTAssertEqual(reason, LCTextSyncUnavailableReasonDisabled);
    self.field.enabled = YES;
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultReady);
    binding.valid = NO;
    XCTAssertEqual([target validateCurrentInput], LCTextSyncInputResultUnavailable);
    XCTAssertNil([LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:&reason]);
}
- (void)testGameBindingReplacementAndLocalChangesRejectWithoutRefreshing {
    self.textView.hidden = YES;
    LCTextSyncTestDelegate *owner = [LCTextSyncTestDelegate new];
    self.field.delegate = owner;
    LCTextSyncGameBindingFixture *binding = [self bindGameField:self.field window:self.window owner:owner];
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self.field resignFirstResponder];
    self.field.hidden = YES;
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    self.field.text = @"local";
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
    XCTAssertEqualObjects(self.field.text, @"local");
    XCTAssertEqual(binding.refreshes, 0u);
    self.field.text = @"A";
    LCTextSyncTestDelegate *replacementOwner = [LCTextSyncTestDelegate new];
    self.field.delegate = replacementOwner;
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
    XCTAssertEqualObjects(self.field.text, @"A");
    XCTAssertEqual(binding.refreshes, 0u);
    self.field.delegate = owner;
    UITextField *replacement = [[UITextField alloc] initWithFrame:self.field.frame];
    binding.testField = replacement;
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(binding.refreshes, 0u);
}
- (void)testReplacementCallbackCancellingSessionStopsLaterNotificationsAndRefresh {
    [self.window endEditing:YES];
    [self.field removeFromSuperview];
    LCTextSyncCallbackField *field = [[LCTextSyncCallbackField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
    self.field = field;
    [self.surface insertSubview:field atIndex:0];
    self.textView.hidden = YES;
    field.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    XCTAssertTrue([field becomeFirstResponder]);
    LCTextSyncTestDelegate *owner = [LCTextSyncTestDelegate new];
    field.delegate = owner;
    [field addTarget:owner action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    LCTextSyncGameBindingFixture *binding = [self bindGameField:field window:self.window owner:owner];
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:field];
    field.text = @"A";
    [field resignFirstResponder];
    field.hidden = YES;
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    __block BOOL current = YES;
    target.shouldContinue = ^BOOL { return current; };
    field.suppressUIKitCallbacks = YES;
    field.onReplace = ^{ current = NO; };
    __block NSUInteger notifications = 0;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:UITextFieldTextDidChangeNotification object:field queue:nil usingBlock:^(NSNotification *note) { notifications++; }];
    @try {
        XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
        XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonSessionChanged);
        XCTAssertEqualObjects(field.text, @"AB");
        XCTAssertEqual(owner.controls, 0u);
        XCTAssertEqual(notifications, 0u);
        XCTAssertEqual(binding.refreshes, 0u);
        XCTAssertEqual(field.delegate, owner);
    } @finally {
        [NSNotificationCenter.defaultCenter removeObserver:token];
    }
}
- (void)testGameControlCallbackInvalidationPreventsRenderedRefresh {
    self.textView.hidden = YES;
    LCTextSyncTestDelegate *owner = [LCTextSyncTestDelegate new];
    self.field.delegate = owner;
    [self.field addTarget:owner action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    LCTextSyncGameBindingFixture *binding = [self bindGameField:self.field window:self.window owner:owner];
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self.field resignFirstResponder];
    self.field.hidden = YES;
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    owner.onControl = ^{ binding.valid = NO; };
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(owner.controls, 1u);
    XCTAssertEqual(binding.refreshes, 0u);
    XCTAssertEqual(self.field.delegate, owner);
}
- (void)testGameEngineInvalidationRejectsEvenWhileObjectiveCDelegateRemainsAlive {
    [self.window endEditing:YES];
    [self.field removeFromSuperview];
    LCTextSyncCallbackField *field = [[LCTextSyncCallbackField alloc] initWithFrame:CGRectMake(10, 20, 260, 44)];
    self.field = field;
    [self.surface insertSubview:field atIndex:0];
    self.textView.hidden = YES;
    field.inputView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    XCTAssertTrue([field becomeFirstResponder]);
    __weak LCTextSyncTestDelegate *weakOwner;
    LCTextSyncInput *target;
    @autoreleasepool {
        // UIKit and Objective-C getters may keep the wrapper alive until the
        // pool drains. Engine liveness must be checked independently of weak
        // zeroing because the game's destructor does not clear its raw pointer.
        LCTextSyncTestDelegate *retainedWrapper = [LCTextSyncTestDelegate new];
        weakOwner = retainedWrapper;
        field.delegate = retainedWrapper;
        LCTextSyncGameBindingFixture *binding = [self bindGameField:field window:self.window owner:retainedWrapper];
        NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:field];
        field.text = @"A";
        [field resignFirstResponder];
        field.hidden = YES;
        target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
        XCTAssertNotNil(target);
        field.suppressUIKitCallbacks = YES;
        field.onReplace = ^{ binding.valid = NO; };
        XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultUnavailable);
        XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonFocusChanged);
        XCTAssertEqual(field.delegate, retainedWrapper);
        XCTAssertNotNil(weakOwner);
        XCTAssertEqual(binding.refreshes, 0u);
        XCTAssertEqualObjects(field.text, @"AB");
    }
    // Keep the adapter and field alive while proving neither its binding nor
    // replay proxy prolonged the wrapper's lifetime beyond UIKit temporaries.
    XCTAssertNotNil(target.responder);
    XCTAssertNil(weakOwner);
    XCTAssertNil(field.delegate);
}
- (void)testGameRefreshRechecksTextAndSessionBeforeAdvancingBaseline {
    self.textView.hidden = YES;
    LCTextSyncGameBindingFixture *binding = [self bindGameField:self.field window:self.window owner:nil];
    NSDictionary *packet = [self packetFrom:@"A" to:@"AB" input:self.field];
    self.field.text = @"A";
    [self.field resignFirstResponder];
    self.field.hidden = YES;
    LCTextSyncInput *target = [LCTextSyncInput inputForWindow:self.window source:NO unavailableReason:NULL];
    XCTAssertNotNil(target);
    __weak UITextField *weakField = self.field;
    binding.onRefresh = ^{ weakField.text = @"game correction"; };
    XCTAssertEqual([target applyPacket:packet], LCTextSyncInputResultMismatch);
    XCTAssertEqualObjects(self.field.text, @"game correction");
    XCTAssertEqual(binding.refreshes, 1u);
    self.field.text = @"A";
    __block BOOL current = YES;
    target.shouldContinue = ^BOOL { return current; };
    binding.onRefresh = ^{ current = NO; };
    NSMutableDictionary *fresh = packet.mutableCopy;
    fresh[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    XCTAssertEqual([target applyPacket:fresh], LCTextSyncInputResultUnavailable);
    XCTAssertEqual(target.lastUnavailableReason, LCTextSyncUnavailableReasonSessionChanged);
    XCTAssertEqual(binding.refreshes, 2u);
}
@end
