#import <XCTest/XCTest.h>
#import "../TweakLoader/TextSyncInput.h"
#import "TapSyncTestWindow.h"

@interface LCTextSyncTestDelegate : NSObject <UITextFieldDelegate, UITextViewDelegate>
@property(nonatomic) NSUInteger validations, changes, controls;
@property(nonatomic) BOOL reject, transform;
@property(nonatomic) NSTimeInterval validationDelay;
@property(nonatomic, copy) void (^onValidate)(void);
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
}
@end

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
    [self.window endEditing:YES];
    [self.surface removeFromSuperview];
    self.surface = nil;
    self.field = nil;
    self.textView = nil;
    self.window = nil;
    [super tearDown];
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
    [self.field unmarkText];
    self.field.text = @"before";
    [self setSelection:NSMakeRange(6, 0) input:self.field];
    NSMutableDictionary *wrong = packet.mutableCopy;
    NSMutableDictionary *signature = [wrong[@"field"] mutableCopy];
    signature[@"identifier"] = @"another-field";
    wrong[@"field"] = signature;
    XCTAssertEqual([target applyPacket:wrong], LCTextSyncInputResultMismatch);
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
}
@end
