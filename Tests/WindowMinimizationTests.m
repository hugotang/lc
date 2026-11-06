#import <XCTest/XCTest.h>
#import "../MultitaskSupport/WindowMinimization.h"
#import "../MultitaskSupport/WindowGridOrder.h"
#import "../MultitaskSupport/WindowGridLayout.h"
#import "TapSyncTestWindow.h"

@interface LCMinimizationTestHost : UIView
@property(nonatomic) NSUInteger layoutPasses;
@property(nonatomic) NSUInteger visibleCountAtLayout;
@end
@implementation LCMinimizationTestHost
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layoutPasses++;
    self.visibleCountAtLayout = 0;
    for (UIView *view in self.subviews) {
        if (!view.hidden && view.alpha > 0) self.visibleCountAtLayout++;
    }
}
@end

@interface WindowMinimizationTests : XCTestCase
@property(nonatomic) LCMinimizationTestHost *host;
@end

@implementation WindowMinimizationTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    UIView *root = LCTapSyncTestHostWindow().rootViewController.view;
    XCTAssertNotNil(root.window);
    self.host = [[LCMinimizationTestHost alloc] initWithFrame:CGRectMake(0, 0, 800, 1000)];
    [root addSubview:self.host];
}

- (void)tearDown {
    [self.host removeFromSuperview];
    self.host = nil;
    [super tearDown];
}

- (LCWindowMinimization *)addWindowWithFrame:(CGRect)frame availability:(BOOL (^)(void))availability {
    UIView *view = [[UIView alloc] initWithFrame:frame];
    view.backgroundColor = UIColor.systemBlueColor;
    [self.host addSubview:view];
    return [[LCWindowMinimization alloc] initWithView:view availability:availability];
}

- (void)waitForHiddenWindows:(NSArray<LCWindowMinimization *> *)windows {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        for (LCWindowMinimization *window in windows) if (!window.view.hidden) return NO;
        return YES;
    }];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:3], XCTWaiterResultCompleted);
}

- (void)waitPastAnimationDeadline {
    XCTestExpectation *expectation = [self expectationWithDescription:@"Original minimize animation has completed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [expectation fulfill];
    });
    [self waitForExpectations:@[expectation] timeout:3];
}

- (void)testFourFloatingWindowsRestoreFramesScaleAndStackingTogether {
    NSMutableArray<LCWindowMinimization *> *windows = [NSMutableArray array];
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    NSMutableArray<NSValue *> *scales = [NSMutableArray array];
    for (NSUInteger index = 0; index < 4; index++) {
        CGRect frame = CGRectMake(25 + 35 * index, 50 + 45 * index, 250 + 20 * index, 350 + 25 * index);
        LCWindowMinimization *window = [self addWindowWithFrame:frame availability:^BOOL { return YES; }];
        UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 140)];
        content.transform = CGAffineTransformMakeScale(0.5 + 0.5 * index, 0.5 + 0.5 * index);
        [window.view addSubview:content];
        [windows addObject:window];
        [frames addObject:[NSValue valueWithCGRect:frame]];
        [scales addObject:[NSValue valueWithCGAffineTransform:content.transform]];
    }
    [self.host bringSubviewToFront:windows[1].view];
    [self.host bringSubviewToFront:windows[0].view];
    NSArray *stacking = self.host.subviews.copy;
    for (LCWindowMinimization *window in windows) XCTAssertTrue([window minimize]);
    [self waitForHiddenWindows:windows];
    [self.host layoutIfNeeded];
    self.host.layoutPasses = 0;
    __block NSUInteger callbacks = 0;
    XCTAssertEqual([LCWindowMinimization restoreWindows:windows inHost:self.host layout:^(NSArray<UIView *> *restored) {
        callbacks++;
        XCTAssertEqual(restored.count, 4);
        [self.host layoutIfNeeded];
    }], 4);
    XCTAssertEqual(callbacks, 1);
    XCTAssertEqual(self.host.layoutPasses, 1);
    XCTAssertEqual(self.host.visibleCountAtLayout, 4);
    XCTAssertEqualObjects(self.host.subviews, stacking);
    for (NSUInteger index = 0; index < windows.count; index++) {
        UIView *view = windows[index].view;
        XCTAssertFalse(view.hidden);
        XCTAssertFalse(windows[index].canRestore);
        XCTAssertEqual(view.alpha, 1);
        XCTAssertTrue(CGAffineTransformIsIdentity(view.transform));
        XCTAssertTrue(CGRectEqualToRect(view.frame, frames[index].CGRectValue));
        XCTAssertTrue(CGAffineTransformEqualToTransform(view.subviews.firstObject.transform, scales[index].CGAffineTransformValue));
    }
}

- (void)testPartialRestoreSkipsVisibleUnavailableAndUntrackedHiddenWindows {
    __block BOOL available = YES;
    LCWindowMinimization *minimized = [self addWindowWithFrame:CGRectMake(10, 20, 200, 300) availability:^BOOL { return YES; }];
    LCWindowMinimization *unavailable = [self addWindowWithFrame:CGRectMake(40, 50, 220, 330) availability:^BOOL { return available; }];
    LCWindowMinimization *visible = [self addWindowWithFrame:CGRectMake(70, 80, 230, 340) availability:^BOOL { return YES; }];
    LCWindowMinimization *otherPresentation = [self addWindowWithFrame:CGRectMake(100, 110, 240, 350) availability:^BOOL { return YES; }];
    otherPresentation.view.hidden = YES;
    [minimized minimize];
    [unavailable minimize];
    [self waitForHiddenWindows:@[minimized, unavailable]];
    available = NO;
    CGRect visibleFrame = visible.view.frame;
    __block NSUInteger callbacks = 0;
    XCTAssertEqual(([LCWindowMinimization restoreWindows:@[minimized, unavailable, visible, otherPresentation]
                                                inHost:self.host layout:^(NSArray<UIView *> *restored) {
        callbacks++;
        XCTAssertEqualObjects(restored, (@[minimized.view]));
    }]), 1);
    XCTAssertEqual(callbacks, 1);
    XCTAssertFalse(minimized.view.hidden);
    XCTAssertTrue(unavailable.view.hidden);
    XCTAssertTrue(otherPresentation.view.hidden);
    XCTAssertFalse(visible.view.hidden);
    XCTAssertTrue(CGRectEqualToRect(visible.view.frame, visibleFrame));
    available = YES;
    XCTAssertTrue(unavailable.canRestore);
    XCTAssertTrue([unavailable restore]);
}

- (void)testImmediateRestoreSurvivesOldMinimizeCompletion {
    CGRect frame = CGRectMake(30, 50, 300, 450);
    LCWindowMinimization *window = [self addWindowWithFrame:frame availability:^BOOL { return YES; }];
    XCTAssertTrue([window minimize]);
    XCTAssertTrue(window.canRestore);
    XCTAssertEqual([LCWindowMinimization restoreWindows:@[window] inHost:self.host layout:^(NSArray *restored) {
        XCTAssertFalse(window.view.hidden);
        XCTAssertTrue(CGRectEqualToRect(window.view.frame, frame));
    }], 1);
    [self waitPastAnimationDeadline];
    XCTAssertFalse(window.view.hidden);
    XCTAssertEqual(window.view.alpha, 1);
    XCTAssertFalse(window.isMinimized);
    XCTAssertTrue(CGRectEqualToRect(window.view.frame, frame));
}

- (void)testNewMinimizeAfterRestoreOwnsItsCompletion {
    CGRect frame = CGRectMake(30, 50, 300, 450);
    LCWindowMinimization *window = [self addWindowWithFrame:frame availability:^BOOL { return YES; }];
    [window minimize];
    XCTAssertTrue([window restore]);
    XCTAssertTrue([window minimize]);
    [self waitForHiddenWindows:@[window]];
    XCTAssertTrue(window.canRestore);
    XCTAssertTrue([window restore]);
    [self waitPastAnimationDeadline];
    XCTAssertFalse(window.view.hidden);
    XCTAssertEqual(window.view.alpha, 1);
    XCTAssertTrue(CGRectEqualToRect(window.view.frame, frame));
}

- (void)testIndividualRecoveryRemovesWindowFromBulkCandidates {
    LCWindowMinimization *window = [self addWindowWithFrame:CGRectMake(30, 50, 300, 450) availability:^BOOL { return YES; }];
    [window minimize];
    // Individual Dock/workspace recovery owns its own appearance animation after this handoff.
    [window invalidate];
    window.view.hidden = NO;
    window.view.alpha = 1;
    [self waitPastAnimationDeadline];
    XCTAssertFalse(window.view.hidden);
    XCTAssertFalse(window.canRestore);
    XCTAssertEqual([LCWindowMinimization restoreWindows:@[window] inHost:self.host layout:^(NSArray *restored) {
        XCTFail(@"No minimized window remains");
    }], 0);
}

- (void)testPiPOrClosingPresentationCannotBeReopenedByOldMinimize {
    LCWindowMinimization *window = [self addWindowWithFrame:CGRectMake(30, 50, 300, 450) availability:^BOOL { return YES; }];
    [window minimize];
    [window invalidate];
    // Another presentation owns visibility now. Even if it later becomes eligible, it is not an ordinary minimize.
    window.view.alpha = 0.6;
    CGFloat alpha = window.view.alpha;
    window.view.hidden = YES;
    [self waitPastAnimationDeadline];
    XCTAssertEqual(window.view.alpha, alpha);
    XCTAssertTrue(window.view.hidden);
    XCTAssertFalse(window.canRestore);
    XCTAssertEqual([LCWindowMinimization restoreWindows:@[window] inHost:self.host layout:^(NSArray *restored) {
        XCTFail(@"Presentation handoff must not restore");
    }], 0);
}

- (void)testRepeatedActionsAreIdempotent {
    LCWindowMinimization *window = [self addWindowWithFrame:CGRectMake(30, 50, 300, 450) availability:^BOOL { return YES; }];
    XCTAssertTrue([window minimize]);
    XCTAssertFalse([window minimize]);
    [self waitForHiddenWindows:@[window]];
    XCTAssertFalse([window minimize]);
    XCTAssertTrue([window restore]);
    XCTAssertFalse([window restore]);
    XCTAssertEqual(([LCWindowMinimization restoreWindows:@[window, window] inHost:self.host layout:^(NSArray *restored) {
        XCTFail(@"Repeated restore must not trigger layout");
    }]), 0);
    [window minimize];
    XCTAssertEqual(([LCWindowMinimization restoreWindows:@[window, window] inHost:self.host layout:^(NSArray *restored) {
        XCTAssertEqual(restored.count, 1);
    }]), 1);
}

- (void)testRemovedAndReparentedWindowsDoNotRestoreIntoOldHost {
    LCWindowMinimization *window = [self addWindowWithFrame:CGRectMake(30, 50, 300, 450) availability:^BOOL { return YES; }];
    [window minimize];
    [self waitForHiddenWindows:@[window]];
    UIView *otherHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 700, 900)];
    [self.host.superview addSubview:otherHost];
    [otherHost addSubview:window.view];
    XCTAssertTrue(window.canRestore);
    XCTAssertEqual([LCWindowMinimization restoreWindows:@[window] inHost:self.host layout:^(NSArray *restored) {
        XCTFail(@"Old host must not restore a reparented window");
    }], 0);
    UIView *view = window.view;
    [view removeFromSuperview];
    XCTAssertFalse(window.canRestore);
    XCTAssertFalse([window restore]);
    [otherHost addSubview:view];
    XCTAssertEqual([LCWindowMinimization restoreWindows:@[window] inHost:otherHost layout:^(NSArray *restored) {
        XCTAssertEqualObjects(restored, (@[view]));
    }], 1);
    XCTAssertFalse(view.hidden);
    [otherHost removeFromSuperview];
}

- (void)testDiscardedViewsAreNotRetainedByMinimizationState {
    __weak UIView *discarded;
    LCWindowMinimization *state;
    @autoreleasepool {
        UIView *view = [UIView new];
        discarded = view;
        state = [[LCWindowMinimization alloc] initWithView:view availability:^BOOL { return YES; }];
    }
    XCTAssertNil(discarded);
    XCTAssertNil(state.view);
    XCTAssertFalse(state.canRestore);
    XCTAssertFalse([state restore]);
}

- (void)testGridOrderAndUnequalProportionsReturnInOneLayout {
    LCWindowGridOrder *order = [LCWindowGridOrder new];
    NSMutableArray<LCWindowMinimization *> *windows = [NSMutableArray array];
    for (NSUInteger index = 0; index < 4; index++) {
        LCWindowMinimization *window = [self addWindowWithFrame:CGRectZero availability:^BOOL { return YES; }];
        [order addWindow:window.view];
        [windows addObject:window];
    }
    XCTAssertTrue([order swapWindow:windows[0].view withWindow:windows[3].view visibleWindows:order.windows]);
    NSArray<UIView *> *slots = order.windows;
    [self.host bringSubviewToFront:windows[2].view];
    __block NSUInteger layouts = 0;
    void (^applyGrid)(void) = ^{
        layouts++;
        NSMutableArray<UIView *> *visible = [NSMutableArray array];
        for (UIView *view in order.windows) if (!view.hidden && view.alpha > 0) [visible addObject:view];
        double rows[] = {0.42}, columns[] = {0.61};
        LCWindowGridLayout grid = LCWindowGridLayoutMake(visible.count, 800, 1000, 2, 88);
        for (NSUInteger index = 0; index < visible.count; index++) {
            LCWindowGridRect frame = LCWindowGridFrameWithDividers(grid, index, rows, columns, columns);
            visible[index].frame = CGRectMake(frame.x, frame.y, frame.width, frame.height);
        }
    };
    applyGrid();
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (UIView *view in slots) [frames addObject:[NSValue valueWithCGRect:view.frame]];
    for (LCWindowMinimization *window in windows) [window minimize];
    [self waitForHiddenWindows:windows];
    // Restore order differs from UIKit focus order, just as it does in the production host.
    NSArray *orderedStates = @[windows[3], windows[1], windows[2], windows[0]];
    layouts = 0;
    XCTAssertEqual([LCWindowMinimization restoreWindows:orderedStates inHost:self.host layout:^(NSArray<UIView *> *restored) {
        XCTAssertEqualObjects(restored, slots);
        applyGrid();
    }], 4);
    XCTAssertEqual(layouts, 1);
    XCTAssertEqualObjects(order.windows, slots);
    for (NSUInteger index = 0; index < slots.count; index++) {
        XCTAssertTrue(CGRectEqualToRect(slots[index].frame, frames[index].CGRectValue));
    }
}
@end
