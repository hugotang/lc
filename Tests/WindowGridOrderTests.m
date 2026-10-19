#import "../MultitaskSupport/WindowGridOrder.h"
#include <assert.h>
#include <stdio.h>

// Different windows may belong to the same app, but must always be compared by identity.
@interface EqualWindow : NSObject
@end
@implementation EqualWindow
- (BOOL)isEqual:(id)object { return [object isKindOfClass:EqualWindow.class]; }
- (NSUInteger)hash { return 1; }
@end

static LCWindowGridOrder *makeOrder(NSArray *windows) {
    LCWindowGridOrder *order = [LCWindowGridOrder new];
    for (id window in windows) [order addWindow:window];
    return order;
}

static void assertOrder(LCWindowGridOrder *order, NSArray *expected) {
    NSArray *actual = order.windows;
    assert(actual.count == expected.count);
    for (NSUInteger i = 0; i < actual.count; ++i) assert(actual[i] == expected[i]);
}

static void testHiddenWindowsAndUndo(void) {
    NSObject *a = [NSObject new], *b = [NSObject new], *c = [NSObject new], *d = [NSObject new], *e = [NSObject new];
    NSArray *original = @[a, b, c, d, e];
    LCWindowGridOrder *order = makeOrder(original);
    NSArray *visible = @[a, c, d]; // b is minimized and e is in Picture-in-Picture.
    assert([order swapWindow:a withWindow:d visibleWindows:visible]);
    assertOrder(order, (@[d, b, c, a, e]));
    assert([order canUndoSwapWithVisibleWindows:visible]);
    assert(![order canUndoSwapWithVisibleWindows:(@[c, d])]);
    assert(![order undoSwapWithVisibleWindows:(@[c, d])]);
    assertOrder(order, (@[d, b, c, a, e]));
    // Restoring a window makes undo available again, without moving the hidden entries.
    assert([order undoSwapWithVisibleWindows:visible]);
    assertOrder(order, original);
    assert(![order canUndoSwapWithVisibleWindows:visible]);
}

static void testInvalidChoicesAndLastSwapOnly(void) {
    NSObject *a = [NSObject new], *b = [NSObject new], *c = [NSObject new], *outside = [NSObject new];
    NSArray *visible = @[a, b, c];
    LCWindowGridOrder *order = makeOrder(visible);
    assert([order swapWindow:a withWindow:b visibleWindows:visible]);
    assert(![order swapWindow:a withWindow:a visibleWindows:visible]);
    assert(![order swapWindow:a withWindow:outside visibleWindows:visible]);
    assert(![order swapWindow:a withWindow:nil visibleWindows:visible]);
    assert(![order swapWindow:a withWindow:c visibleWindows:(@[a, b])]);
    assertOrder(order, (@[b, a, c]));
    assert([order canUndoSwapWithVisibleWindows:visible]);
    assert([order swapWindow:b withWindow:c visibleWindows:visible]);
    assertOrder(order, (@[c, a, b]));
    assert([order undoSwapWithVisibleWindows:visible]);
    assertOrder(order, (@[b, a, c]));
    assert(![order undoSwapWithVisibleWindows:visible]);
}

static void testWindowLifecycleAndIdentity(void) {
    EqualWindow *a = [EqualWindow new], *b = [EqualWindow new], *c = [EqualWindow new], *d = [EqualWindow new];
    LCWindowGridOrder *order = makeOrder(@[a, b, c]);
    [order addWindow:a];
    assertOrder(order, (@[a, b, c]));
    assert([order swapWindow:a withWindow:c visibleWindows:order.windows]);
    assertOrder(order, (@[c, b, a]));
    [order removeWindow:b];
    [order addWindow:d];
    assertOrder(order, (@[c, a, d]));
    assert([order undoSwapWithVisibleWindows:order.windows]);
    assertOrder(order, (@[a, c, d]));
    assert([order swapWindow:a withWindow:c visibleWindows:order.windows]);
    [order removeWindow:a];
    assertOrder(order, (@[c, d]));
    assert(![order canUndoSwapWithVisibleWindows:order.windows]);
    [order addWindow:b];
    assertOrder(order, (@[c, d, b]));
    assert(![order undoSwapWithVisibleWindows:order.windows]);
    [order removeWindow:a];
    assertOrder(order, (@[c, d, b]));
}

static void testAllPairs(void) {
    for (NSUInteger count = 2; count <= 32; ++count) {
        NSMutableArray *windows = [NSMutableArray array];
        for (NSUInteger i = 0; i < count; ++i) [windows addObject:[NSObject new]];
        LCWindowGridOrder *order = makeOrder(windows);
        for (NSUInteger first = 0; first < count; ++first) {
            for (NSUInteger second = first + 1; second < count; ++second) {
                assert([order swapWindow:windows[first] withWindow:windows[second] visibleWindows:windows]);
                NSArray *swapped = order.windows;
                for (NSUInteger i = 0; i < count; ++i) {
                    NSUInteger source = i == first ? second : i == second ? first : i;
                    assert(swapped[i] == windows[source]);
                }
                assert([order undoSwapWithVisibleWindows:windows]);
                assertOrder(order, windows);
            }
        }
    }
}

static void testRestoringOrder(void) {
    id a = [EqualWindow new], b = [EqualWindow new], c = [EqualWindow new], unknown = [EqualWindow new];
    LCWindowGridOrder *order = makeOrder(@[a, b, c]);
    assert(([order swapWindow:a withWindow:b visibleWindows:@[a, b, c]]));
    [order restoreOrderWithWindows:@[c, unknown, c, a]];
    assertOrder(order, @[c, a, b]);
    assert((![order canUndoSwapWithVisibleWindows:@[a, b, c]]));
    [order restoreOrderWithWindows:@[]];
    assertOrder(order, @[c, a, b]);
    [order removeWindow:c];
    [order restoreOrderWithWindows:@[c, b]];
    assertOrder(order, @[b, a]);
}

int main(void) {
    @autoreleasepool {
        testHiddenWindowsAndUndo();
        testInvalidChoicesAndLastSwapOnly();
        testWindowLifecycleAndIdentity();
        testAllPairs();
        testRestoringOrder();
        puts("Window grid order tests passed (5,456 swap/undo pairs, hidden windows, identity and lifecycle checks).");
    }
    return 0;
}
