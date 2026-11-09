#import "TextSyncInput.h"

NSString *LCTextSyncUnavailableReasonName(LCTextSyncUnavailableReason reason) {
    switch (reason) {
        case LCTextSyncUnavailableReasonNone: return @"none";
        case LCTextSyncUnavailableReasonNoFocusedInput: return @"noFocusedInput";
        case LCTextSyncUnavailableReasonUnsupportedResponder: return @"unsupportedResponder";
        case LCTextSyncUnavailableReasonAmbiguousInput: return @"ambiguousInput";
        case LCTextSyncUnavailableReasonNotVisible: return @"notVisible";
        case LCTextSyncUnavailableReasonDisabled: return @"disabled";
        case LCTextSyncUnavailableReasonSecure: return @"secure";
        case LCTextSyncUnavailableReasonComposing: return @"composing";
        case LCTextSyncUnavailableReasonInvalidSelection: return @"invalidSelection";
        case LCTextSyncUnavailableReasonInvalidText: return @"invalidText";
        case LCTextSyncUnavailableReasonUnsupportedHierarchy: return @"unsupportedHierarchy";
        case LCTextSyncUnavailableReasonFocusChanged: return @"focusChanged";
        case LCTextSyncUnavailableReasonWrongThread: return @"wrongThread";
        case LCTextSyncUnavailableReasonSessionChanged: return @"sessionChanged";
    }
    return @"unknown";
}

static BOOL LCTextSyncVisible(UIView *view, UIWindow *window) {
    if (!view || view.window != window || window.hidden || window.alpha <= 0.01) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01 || !ancestor.userInteractionEnabled) return NO;
    }
    return !CGRectIsEmpty(view.bounds) && CGRectIntersectsRect([view convertRect:view.bounds toView:window], window.bounds);
}

static UIView<UITextInput> *LCTextSyncFocusedInput(UIWindow *window, LCTextSyncUnavailableReason *reason) {
    *reason = LCTextSyncUnavailableReasonNoFocusedInput;
    UIView *root = window.rootViewController.viewIfLoaded;
    if (!root) { *reason = LCTextSyncUnavailableReasonUnsupportedHierarchy; return nil; }
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    UIView<UITextInput> *found = nil;
    NSUInteger visited = 0;
    while (pending.count) {
        if (++visited > 2048) { *reason = LCTextSyncUnavailableReasonUnsupportedHierarchy; return nil; }
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.isFirstResponder) {
            if (found) { *reason = LCTextSyncUnavailableReasonAmbiguousInput; return nil; }
            if (!([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class])) {
                *reason = LCTextSyncUnavailableReasonUnsupportedResponder; return nil;
            }
            if (!LCTextSyncVisible(view, window)) { *reason = LCTextSyncUnavailableReasonNotVisible; return nil; }
            if (([view isKindOfClass:UITextField.class] && !((UITextField *)view).enabled) ||
                ([view isKindOfClass:UITextView.class] && !((UITextView *)view).editable)) {
                *reason = LCTextSyncUnavailableReasonDisabled; return nil;
            }
            found = (UIView<UITextInput> *)view;
            // A focused UITextField can also expose its private field editor as
            // a first responder. It belongs to this public input, not another
            // independently focused field. Still inspect all sibling branches.
            continue;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    if (found) *reason = LCTextSyncUnavailableReasonNone;
    return found;
}

static UIView<UITextInput> *LCTextSyncInputForRole(UIWindow *window, BOOL source, LCTextSyncUnavailableReason *reason) {
    UIView<UITextInput> *focused = LCTextSyncFocusedInput(window, reason);
    if (focused || source || *reason != LCTextSyncUnavailableReasonNoFocusedInput) return focused;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window.rootViewController.viewIfLoaded];
    UIView<UITextInput> *found = nil;
    NSUInteger visited = 0;
    while (pending.count) {
        if (++visited > 2048) { *reason = LCTextSyncUnavailableReasonUnsupportedHierarchy; return nil; }
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        BOOL standard = [view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class];
        if (standard) {
            UIView<UITextInput> *input = (UIView<UITextInput> *)view;
            BOOL editable = [view isKindOfClass:UITextField.class] ? ((UITextField *)view).enabled : ((UITextView *)view).editable;
            if (LCTextSyncVisible(view, window) && editable && !input.isSecureTextEntry) {
                if (found) { *reason = LCTextSyncUnavailableReasonAmbiguousInput; return nil; }
                found = input;
            }
            // A standard input's private editors are implementation details,
            // never additional candidates or substitutes for a hidden field.
            continue;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    if (found) *reason = LCTextSyncUnavailableReasonNone;
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
@property(nonatomic, readwrite) LCTextSyncUnavailableReason lastUnavailableReason;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, copy) NSDictionary *field;
@property(nonatomic, copy) NSString *baseline;
@property(nonatomic) BOOL source;
@end

@implementation LCTextSyncInput
+ (instancetype)inputForWindow:(UIWindow *)window {
    return [self inputForWindow:window unavailableReason:NULL];
}
+ (instancetype)inputForWindow:(UIWindow *)window unavailableReason:(LCTextSyncUnavailableReason *)reason {
    return [self inputForWindow:window source:YES unavailableReason:reason];
}
+ (instancetype)inputForWindow:(UIWindow *)window source:(BOOL)source unavailableReason:(LCTextSyncUnavailableReason *)reason {
    LCTextSyncUnavailableReason failure = LCTextSyncUnavailableReasonNone;
    if (!reason) reason = &failure;
    *reason = LCTextSyncUnavailableReasonNone;
    if (!NSThread.isMainThread) { *reason = LCTextSyncUnavailableReasonWrongThread; return nil; }
    UIView<UITextInput> *input = LCTextSyncInputForRole(window, source, reason);
    if (!input) return nil;
    if (input.isSecureTextEntry) { *reason = LCTextSyncUnavailableReasonSecure; return nil; }
    if (input.markedTextRange) { *reason = LCTextSyncUnavailableReasonComposing; return nil; }
    NSString *text = LCTextSyncText(input);
    NSDictionary *field = LCTextSyncField(input, window);
    if (!LCTextSyncStringIsValid(text, LCTextSyncMaximumLength)) { *reason = LCTextSyncUnavailableReasonInvalidText; return nil; }
    if (!field) { *reason = LCTextSyncUnavailableReasonUnsupportedHierarchy; return nil; }
    if ((source || input.isFirstResponder) && !LCTextSyncSelection(input, text, NULL)) { *reason = LCTextSyncUnavailableReasonInvalidSelection; return nil; }
    LCTextSyncInput *adapter = [self new];
    adapter.responder = input;
    adapter.window = window;
    adapter.field = field;
    adapter.baseline = text;
    adapter.source = source;
    return adapter;
}
- (LCTextSyncInputResult)validateCurrentInput {
    self.lastUnavailableReason = LCTextSyncUnavailableReasonNone;
    UIView<UITextInput> *input = self.responder;
    if (!NSThread.isMainThread) { self.lastUnavailableReason = LCTextSyncUnavailableReasonWrongThread; return LCTextSyncInputResultUnavailable; }
    if (!input || !self.window) { self.lastUnavailableReason = LCTextSyncUnavailableReasonFocusChanged; return LCTextSyncInputResultUnavailable; }
    if (input.isSecureTextEntry) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSecure; return LCTextSyncInputResultUnavailable; }
    LCTextSyncUnavailableReason failure;
    UIView<UITextInput> *focused = LCTextSyncInputForRole(self.window, self.source, &failure);
    if (focused != input) {
        self.lastUnavailableReason = !focused && failure != LCTextSyncUnavailableReasonNoFocusedInput ? failure : LCTextSyncUnavailableReasonFocusChanged;
        return LCTextSyncInputResultUnavailable;
    }
    if (![LCTextSyncField(input, self.window) isEqual:self.field]) {
        self.lastUnavailableReason = LCTextSyncUnavailableReasonUnsupportedHierarchy;
        return LCTextSyncInputResultMismatch;
    }
    NSString *text = LCTextSyncText(input);
    if (!LCTextSyncStringIsValid(text, LCTextSyncMaximumLength)) { self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidText; return LCTextSyncInputResultUnavailable; }
    if ((self.source || input.isFirstResponder) && !LCTextSyncSelection(input, text, NULL)) { self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidSelection; return LCTextSyncInputResultUnavailable; }
    return LCTextSyncInputResultReady;
}
- (NSDictionary *)captureEditAtTime:(NSTimeInterval)time result:(LCTextSyncInputResult *)result {
    self.lastUnavailableReason = LCTextSyncUnavailableReasonNone;
    LCTextSyncInputResult status = [self validateCurrentInput];
    if (!isfinite(time) || time < 0) status = LCTextSyncInputResultInvalid;
    if (result) *result = status;
    if (status != LCTextSyncInputResultReady || self.responder.markedTextRange) return nil;
    NSString *text = LCTextSyncText(self.responder).copy;
    if ([text isEqual:self.baseline]) return nil;
    NSRange selection;
    if (!LCTextSyncSelection(self.responder, text, &selection)) {
        self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidSelection;
        if (result) *result = LCTextSyncInputResultUnavailable;
        return nil;
    }
    NSDictionary *packet = @{@"timestamp": @(time), @"before": self.baseline, @"after": text,
        @"selectionLocation": @(selection.location), @"selectionLength": @(selection.length), @"field": self.field};
    if (!LCTextSyncPacketIsValid(packet)) { if (result) *result = LCTextSyncInputResultInvalid; return nil; }
    self.baseline = text;
    return packet;
}
- (LCTextSyncInputResult)applyPacket:(NSDictionary *)packet {
    self.lastUnavailableReason = LCTextSyncUnavailableReasonNone;
    if (!LCTextSyncPacketIsValid(packet)) return LCTextSyncInputResultInvalid;
    if (self.shouldContinue && !self.shouldContinue()) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSessionChanged; return LCTextSyncInputResultUnavailable; }
    if (!LCTextSyncPacketIsFresh(packet, NSProcessInfo.processInfo.systemUptime)) return LCTextSyncInputResultExpired;
    LCTextSyncInputResult status = [self validateCurrentInput];
    if (status != LCTextSyncInputResultReady) return status;
    UIView<UITextInput> *input = self.responder;
    BOOL passive = !self.source && !input.isFirstResponder;
    if (input.markedTextRange) { self.lastUnavailableReason = LCTextSyncUnavailableReasonComposing; return LCTextSyncInputResultUnavailable; }
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
    if (self.shouldContinue && !self.shouldContinue()) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSessionChanged; return LCTextSyncInputResultUnavailable; }
    if ([self validateCurrentInput] != LCTextSyncInputResultReady) return LCTextSyncInputResultMismatch;
    if (passive && input.isFirstResponder) { self.lastUnavailableReason = LCTextSyncUnavailableReasonFocusChanged; return LCTextSyncInputResultMismatch; }
    if (input.markedTextRange) { self.lastUnavailableReason = LCTextSyncUnavailableReasonComposing; return LCTextSyncInputResultMismatch; }
    if (![LCTextSyncText(input) isEqual:before]) return LCTextSyncInputResultMismatch;
    if (!LCTextSyncPacketIsFresh(packet, NSProcessInfo.processInfo.systemUptime)) return LCTextSyncInputResultExpired;
    delegate = field ? (id)field.delegate : (id)view.delegate;
    UITextPosition *start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)replacementRange.location];
    UITextPosition *end = start ? [input positionFromPosition:start offset:(NSInteger)replacementRange.length] : nil;
    UITextRange *range = start && end ? [input textRangeFromPosition:start toPosition:end] : nil;
    if (!range) { self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidSelection; return LCTextSyncInputResultUnavailable; }
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
        if (self.shouldContinue && !self.shouldContinue()) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSessionChanged; return LCTextSyncInputResultUnavailable; }
        if (passive && input.isFirstResponder) { self.lastUnavailableReason = LCTextSyncUnavailableReasonFocusChanged; return LCTextSyncInputResultMismatch; }
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
    if (self.shouldContinue && !self.shouldContinue()) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSessionChanged; return LCTextSyncInputResultUnavailable; }
    if ([self validateCurrentInput] != LCTextSyncInputResultReady) return LCTextSyncInputResultMismatch;
    if (passive && input.isFirstResponder) { self.lastUnavailableReason = LCTextSyncUnavailableReasonFocusChanged; return LCTextSyncInputResultMismatch; }
    if (input.markedTextRange) { self.lastUnavailableReason = LCTextSyncUnavailableReasonComposing; return LCTextSyncInputResultMismatch; }
    if (![LCTextSyncText(input) isEqual:after]) return LCTextSyncInputResultMismatch;
    // Unfocused followers need no caret. Setting a selection can acquire the
    // keyboard in custom controls; replay only the validated document edit.
    if (passive) {
        self.baseline = after;
        return LCTextSyncInputResultReady;
    }
    NSUInteger location = [packet[@"selectionLocation"] unsignedIntegerValue], length = [packet[@"selectionLength"] unsignedIntegerValue];
    start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)location];
    end = start ? [input positionFromPosition:start offset:(NSInteger)length] : nil;
    if (!start || !end) { self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidSelection; return LCTextSyncInputResultUnavailable; }
    input.selectedTextRange = [input textRangeFromPosition:start toPosition:end];
    NSRange actual;
    if (self.shouldContinue && !self.shouldContinue()) { self.lastUnavailableReason = LCTextSyncUnavailableReasonSessionChanged; return LCTextSyncInputResultUnavailable; }
    if (!LCTextSyncSelection(input, after, &actual) || !NSEqualRanges(actual, NSMakeRange(location, length))) {
        self.lastUnavailableReason = LCTextSyncUnavailableReasonInvalidSelection;
        return LCTextSyncInputResultMismatch;
    }
    if (![LCTextSyncText(input) isEqual:after]) return LCTextSyncInputResultMismatch;
    self.baseline = after;
    return LCTextSyncInputResultReady;
}
@end
