#import "TextSyncInput.h"

static BOOL LCTextSyncVisible(UIView *view, UIWindow *window) {
    if (!view || view.window != window || window.hidden || window.alpha <= 0.01) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01 || !ancestor.userInteractionEnabled) return NO;
    }
    return !CGRectIsEmpty(view.bounds) && CGRectIntersectsRect([view convertRect:view.bounds toView:window], window.bounds);
}

static UIView<UITextInput> *LCTextSyncFocusedInput(UIWindow *window) {
    UIView *root = window.rootViewController.viewIfLoaded;
    if (!root) return nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    UIView<UITextInput> *found = nil;
    NSUInteger visited = 0;
    while (pending.count) {
        if (++visited > 2048) return nil;
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.isFirstResponder) {
            if (found || !([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) ||
                !LCTextSyncVisible(view, window)) return nil;
            if ([view isKindOfClass:UITextField.class] && !((UITextField *)view).enabled) return nil;
            if ([view isKindOfClass:UITextView.class] && !((UITextView *)view).editable) return nil;
            found = (UIView<UITextInput> *)view;
            // A focused UITextField can also expose its private field editor as
            // a first responder. It belongs to this public input, not another
            // independently focused field. Still inspect all sibling branches.
            continue;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    return found;
}

static NSDictionary *LCTextSyncField(UIView<UITextInput> *input, UIWindow *window) {
    UIView *root = window.rootViewController.viewIfLoaded;
    NSMutableArray *path = [NSMutableArray array];
    UIView *view = input;
    while (view && view != root) {
        if (path.count >= 64 || !view.superview) return nil;
        NSUInteger index = [view.superview.subviews indexOfObjectIdenticalTo:view];
        if (index == NSNotFound || index > 4095) return nil;
        [path insertObject:@(index) atIndex:0];
        view = view.superview;
    }
    if (view != root) return nil;
    NSDictionary *field = @{@"kind": [input isKindOfClass:UITextField.class] ? @"field" : @"view",
        @"path": path.copy, @"identifier": input.accessibilityIdentifier ?: @""};
    return LCTextSyncFieldIsValid(field) ? field : nil;
}

static NSString *LCTextSyncText(UIView<UITextInput> *input) {
    if ([input isKindOfClass:UITextField.class]) return ((UITextField *)input).text ?: @"";
    if ([input isKindOfClass:UITextView.class]) return ((UITextView *)input).text ?: @"";
    return nil;
}

static BOOL LCTextSyncSelection(UIView<UITextInput> *input, NSString *text, NSRange *range) {
    UITextRange *selection = input.selectedTextRange;
    if (!selection) return NO;
    NSInteger start = [input offsetFromPosition:input.beginningOfDocument toPosition:selection.start];
    NSInteger end = [input offsetFromPosition:input.beginningOfDocument toPosition:selection.end];
    if (start < 0 || end < start || (NSUInteger)end > text.length ||
        !LCTextSyncIsScalarBoundary(text, (NSUInteger)start) || !LCTextSyncIsScalarBoundary(text, (NSUInteger)end)) return NO;
    if (range) *range = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
    return YES;
}

static BOOL LCTextSyncComposedBoundary(NSString *text, NSUInteger offset) {
    return offset == 0 || offset == text.length || [text rangeOfComposedCharacterSequenceAtIndex:offset].location == offset;
}

// UIKit differs between fields and text views in which callbacks replaceRange:
// delivers. Forward all optional delegate methods and cache only the one edit
// already approved by the app, so its validator is never consulted twice.
@interface LCTextSyncEditObserver : NSObject <UITextFieldDelegate, UITextViewDelegate>
@property(nonatomic, strong) id originalDelegate;
@property(nonatomic) NSRange range;
@property(nonatomic, copy) NSString *replacement;
@property(nonatomic) NSUInteger controlEvents, delegateChanges, notifications;
@end
@implementation LCTextSyncEditObserver
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector { return self.originalDelegate; }
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (NSEqualRanges(range, self.range) && [string isEqual:self.replacement]) return YES;
    return ![self.originalDelegate respondsToSelector:_cmd] || [self.originalDelegate textField:field shouldChangeCharactersInRange:range replacementString:string];
}
- (BOOL)textView:(UITextView *)view shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if (NSEqualRanges(range, self.range) && [text isEqual:self.replacement]) return YES;
    return ![self.originalDelegate respondsToSelector:_cmd] || [self.originalDelegate textView:view shouldChangeTextInRange:range replacementText:text];
}
- (void)textViewDidChange:(UITextView *)view {
    self.delegateChanges++;
    if ([self.originalDelegate respondsToSelector:_cmd]) [self.originalDelegate textViewDidChange:view];
}
- (void)editingChanged:(UITextField *)field { self.controlEvents++; }
@end

@interface LCTextSyncInput ()
@property(nonatomic, weak, readwrite) UIView<UITextInput> *responder;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, copy) NSDictionary *field;
@property(nonatomic, copy) NSString *baseline;
@end

@implementation LCTextSyncInput
+ (instancetype)inputForWindow:(UIWindow *)window {
    if (!NSThread.isMainThread) return nil;
    UIView<UITextInput> *input = LCTextSyncFocusedInput(window);
    if (!input || input.isSecureTextEntry || input.markedTextRange) return nil;
    NSString *text = LCTextSyncText(input);
    NSDictionary *field = LCTextSyncField(input, window);
    if (!LCTextSyncStringIsValid(text, LCTextSyncMaximumLength) || !field || !LCTextSyncSelection(input, text, NULL)) return nil;
    LCTextSyncInput *adapter = [self new];
    adapter.responder = input;
    adapter.window = window;
    adapter.field = field;
    adapter.baseline = text;
    return adapter;
}
- (LCTextSyncInputResult)validateCurrentInput {
    UIView<UITextInput> *input = self.responder;
    if (!NSThread.isMainThread || !input || !self.window || input.isSecureTextEntry ||
        LCTextSyncFocusedInput(self.window) != input) return LCTextSyncInputResultUnavailable;
    if (![LCTextSyncField(input, self.window) isEqual:self.field]) return LCTextSyncInputResultMismatch;
    NSString *text = LCTextSyncText(input);
    if (!LCTextSyncStringIsValid(text, LCTextSyncMaximumLength) || !LCTextSyncSelection(input, text, NULL)) return LCTextSyncInputResultUnavailable;
    return LCTextSyncInputResultReady;
}
- (NSDictionary *)captureEditAtTime:(NSTimeInterval)time result:(LCTextSyncInputResult *)result {
    LCTextSyncInputResult status = [self validateCurrentInput];
    if (!isfinite(time) || time < 0) status = LCTextSyncInputResultInvalid;
    if (result) *result = status;
    if (status != LCTextSyncInputResultReady || self.responder.markedTextRange) return nil;
    NSString *text = LCTextSyncText(self.responder).copy;
    if ([text isEqual:self.baseline]) return nil;
    NSRange selection;
    if (!LCTextSyncSelection(self.responder, text, &selection)) { if (result) *result = LCTextSyncInputResultUnavailable; return nil; }
    NSDictionary *packet = @{@"timestamp": @(time), @"before": self.baseline, @"after": text,
        @"selectionLocation": @(selection.location), @"selectionLength": @(selection.length), @"field": self.field};
    if (!LCTextSyncPacketIsValid(packet)) { if (result) *result = LCTextSyncInputResultInvalid; return nil; }
    self.baseline = text;
    return packet;
}
- (LCTextSyncInputResult)applyPacket:(NSDictionary *)packet {
    if (!LCTextSyncPacketIsValid(packet)) return LCTextSyncInputResultInvalid;
    if (self.shouldContinue && !self.shouldContinue()) return LCTextSyncInputResultUnavailable;
    if (!LCTextSyncPacketIsFresh(packet, NSProcessInfo.processInfo.systemUptime)) return LCTextSyncInputResultExpired;
    LCTextSyncInputResult status = [self validateCurrentInput];
    if (status != LCTextSyncInputResultReady) return status;
    UIView<UITextInput> *input = self.responder;
    if (input.markedTextRange) return LCTextSyncInputResultUnavailable;
    NSString *before = packet[@"before"], *after = packet[@"after"];
    if (![packet[@"field"] isEqual:self.field] || ![LCTextSyncText(input) isEqual:before] || ![self.baseline isEqual:before]) return LCTextSyncInputResultMismatch;
    NSUInteger prefix = 0, suffix = 0;
    while (prefix < before.length && prefix < after.length && [before characterAtIndex:prefix] == [after characterAtIndex:prefix]) prefix++;
    while (prefix && (!LCTextSyncComposedBoundary(before, prefix) || !LCTextSyncComposedBoundary(after, prefix))) prefix--;
    while (suffix < before.length - prefix && suffix < after.length - prefix &&
        [before characterAtIndex:before.length - suffix - 1] == [after characterAtIndex:after.length - suffix - 1]) suffix++;
    while (suffix && (!LCTextSyncComposedBoundary(before, before.length - suffix) || !LCTextSyncComposedBoundary(after, after.length - suffix))) suffix--;
    NSRange replacementRange = NSMakeRange(prefix, before.length - prefix - suffix);
    NSString *replacement = [after substringWithRange:NSMakeRange(prefix, after.length - prefix - suffix)];
    UITextField *field = [input isKindOfClass:UITextField.class] ? (UITextField *)input : nil;
    UITextView *view = [input isKindOfClass:UITextView.class] ? (UITextView *)input : nil;
    id delegate = field ? (id)field.delegate : (id)view.delegate;
    if (field && [delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)] &&
        ![delegate textField:field shouldChangeCharactersInRange:replacementRange replacementString:replacement]) return LCTextSyncInputResultMismatch;
    if (view && [delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)] &&
        ![delegate textView:view shouldChangeTextInRange:replacementRange replacementText:replacement]) return LCTextSyncInputResultMismatch;
    // A validator can change text, focus, or delegate. Never overwrite that work.
    if (self.shouldContinue && !self.shouldContinue()) return LCTextSyncInputResultUnavailable;
    if ([self validateCurrentInput] != LCTextSyncInputResultReady || input.markedTextRange || ![LCTextSyncText(input) isEqual:before]) return LCTextSyncInputResultMismatch;
    if (!LCTextSyncPacketIsFresh(packet, NSProcessInfo.processInfo.systemUptime)) return LCTextSyncInputResultExpired;
    delegate = field ? (id)field.delegate : (id)view.delegate;
    UITextPosition *start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)replacementRange.location];
    UITextPosition *end = start ? [input positionFromPosition:start offset:(NSInteger)replacementRange.length] : nil;
    UITextRange *range = start && end ? [input textRangeFromPosition:start toPosition:end] : nil;
    if (!range) return LCTextSyncInputResultUnavailable;
    LCTextSyncEditObserver *observer = [LCTextSyncEditObserver new];
    observer.originalDelegate = delegate;
    observer.range = replacementRange;
    observer.replacement = replacement;
    NSString *notificationName = field ? UITextFieldTextDidChangeNotification : UITextViewTextDidChangeNotification;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:notificationName object:input queue:nil usingBlock:^(NSNotification *note) { observer.notifications++; }];
    if (field) { [field addTarget:observer action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged]; field.delegate = observer; }
    else view.delegate = observer;
    @try {
        // Delegate validation and custom UITextInput methods run guest code.
        // Recheck immediately before mutation, not only on packet arrival.
        if (self.shouldContinue && !self.shouldContinue()) return LCTextSyncInputResultUnavailable;
        if (!LCTextSyncPacketIsFresh(packet, NSProcessInfo.processInfo.systemUptime)) return LCTextSyncInputResultExpired;
        [input replaceRange:range withText:replacement];
        if (field && observer.controlEvents == 0) [field sendActionsForControlEvents:UIControlEventEditingChanged];
        if (view && observer.delegateChanges == 0) {
            id current = view.delegate;
            if ([current respondsToSelector:@selector(textViewDidChange:)]) [current textViewDidChange:view];
        }
        if (observer.notifications == 0) [NSNotificationCenter.defaultCenter postNotificationName:notificationName object:input];
    } @finally {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        if (field) {
            [field removeTarget:observer action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
            if (field.delegate == observer) field.delegate = observer.originalDelegate;
        } else if (view.delegate == observer) view.delegate = observer.originalDelegate;
    }
    if (self.shouldContinue && !self.shouldContinue()) return LCTextSyncInputResultUnavailable;
    if ([self validateCurrentInput] != LCTextSyncInputResultReady || input.markedTextRange || ![LCTextSyncText(input) isEqual:after]) return LCTextSyncInputResultMismatch;
    NSUInteger location = [packet[@"selectionLocation"] unsignedIntegerValue], length = [packet[@"selectionLength"] unsignedIntegerValue];
    start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)location];
    end = start ? [input positionFromPosition:start offset:(NSInteger)length] : nil;
    if (!start || !end) return LCTextSyncInputResultUnavailable;
    input.selectedTextRange = [input textRangeFromPosition:start toPosition:end];
    NSRange actual;
    if (self.shouldContinue && !self.shouldContinue()) return LCTextSyncInputResultUnavailable;
    if (!LCTextSyncSelection(input, after, &actual) || !NSEqualRanges(actual, NSMakeRange(location, length)) ||
        ![LCTextSyncText(input) isEqual:after]) return LCTextSyncInputResultMismatch;
    self.baseline = after;
    return LCTextSyncInputResultReady;
}
@end
