#import "../MultitaskSupport/TapSyncRecovery.h"
#include <assert.h>
#include <stdio.h>

static NSTimeInterval nextInputTime(void) {
    static NSTimeInterval time;
    return ++time;
}

static LCTapSyncRecovery *recovery(LCTapSyncRecoveryReason reason) {
    return [[LCTapSyncRecovery alloc] initWithSource:@"A" targets:@[@"B", @"C", @"D"] reason:reason afterTime:0];
}

static void acknowledgeAll(LCTapSyncRecovery *state) {
    for (NSString *container in @[@"A", @"B", @"C", @"D"]) {
        assert([state acknowledgeContainer:container revision:0 touching:NO]);
    }
}

static void returnToSource(LCTapSyncRecovery *state, uint64_t revision) {
    assert([state recordInputForContainer:@"A" revision:revision touching:YES began:YES atTime:nextInputTime()]);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"A" revision:revision + 1 touching:NO began:NO atTime:nextInputTime()]);
}

static void testWholeGroupIdleBarrier(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryFollowerInput);
    assert(state.valid && state.pendingContainers.count == 4 && !state.canResume);
    assert(![state acknowledgeContainer:@"unselected" revision:1 touching:NO]);
    assert(![state recordInputForContainer:@"unselected" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert([state recordInputForContainer:@"B" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert([state acknowledgeContainer:@"A" revision:0 touching:NO]);
    assert([state acknowledgeContainer:@"B" revision:1 touching:YES]);
    assert(![state acknowledgeContainer:@"B" revision:1 touching:YES]);
    assert([state acknowledgeContainer:@"C" revision:0 touching:NO]);
    returnToSource(state, 1);
    assert([state recordInputForContainer:@"B" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    // A source return and idle fingers cannot bypass a missing cancellation reply.
    assert(!state.canResume && [state.pendingContainers isEqual:@[@"D"]]);
    assert([state acknowledgeContainer:@"D" revision:0 touching:NO]);
    assert(state.canResume);
}

static void testReturnRequiresNewSourceGesture(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryFollowerInput);
    // A gesture already held on the source when a follower was touched is local.
    assert([state recordInputForContainer:@"A" revision:4 touching:YES began:NO atTime:nextInputTime()]);
    acknowledgeAll(state);
    assert([state recordInputForContainer:@"A" revision:5 touching:NO began:NO atTime:nextInputTime()]);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"B" revision:1 touching:NO began:NO atTime:nextInputTime()]);
    assert(!state.canResume);
    assert(![state recordInputForContainer:@"A" revision:6 touching:NO began:YES atTime:nextInputTime()]);
    returnToSource(state, 6);
    assert(state.canResume);

    // Operating another follower after returning requires returning to the source again.
    assert([state recordInputForContainer:@"C" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert([state recordInputForContainer:@"C" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(!state.canResume);
    returnToSource(state, 8);
    assert(state.canResume);
}

static void testOtherHeldFingersDelayResume(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryFollowerInput);
    acknowledgeAll(state);
    assert([state recordInputForContainer:@"B" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert([state recordInputForContainer:@"D" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    returnToSource(state, 1);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"B" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"D" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(state.canResume);
}

static void testReorderedRepliesAndInput(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryFollowerInput);
    assert([state recordInputForContainer:@"B" revision:2 touching:YES began:YES atTime:nextInputTime()]);
    assert([state acknowledgeContainer:@"B" revision:1 touching:NO]);
    assert([state acknowledgeContainer:@"A" revision:0 touching:NO]);
    assert([state acknowledgeContainer:@"C" revision:0 touching:NO]);
    assert([state acknowledgeContainer:@"D" revision:0 touching:NO]);
    returnToSource(state, 1);
    assert(!state.canResume); // An older idle snapshot cannot release a newer down.
    assert(![state recordInputForContainer:@"B" revision:1 touching:NO began:NO atTime:nextInputTime()]);
    assert(![state recordInputForContainer:@"B" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert([state recordInputForContainer:@"B" revision:3 touching:NO began:NO atTime:nextInputTime()]);
    assert(state.canResume);
    assert(![state recordInputForContainer:@"A" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert(state.canResume);

    state = recovery(LCTapSyncRecoveryFollowerInput);
    assert([state acknowledgeContainer:@"A" revision:2 touching:NO]);
    for (NSString *container in @[@"B", @"C", @"D"]) assert([state acknowledgeContainer:container revision:0 touching:NO]);
    // A suspension snapshot can overtake the source's begin/end notifications.
    // Keep its return signal while trusting the snapshot that all fingers are up.
    assert([state recordInputForContainer:@"A" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert(state.canResume);
    assert([state recordInputForContainer:@"A" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(state.canResume);
}

static void testRotationAndFollowerOverride(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryRotation);
    assert([state recordInputForContainer:@"A" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    acknowledgeAll(state);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"A" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(state.canResume); // Rotation needs no additional return gesture.
    assert([state recordInputForContainer:@"B" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    [state waitForSourceReturnAfter:nextInputTime()];
    assert(state.reason == LCTapSyncRecoveryFollowerInput);
    assert([state recordInputForContainer:@"B" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(!state.canResume);
    returnToSource(state, 3);
    assert(state.canResume);
}

static void testReturnOrderingAcrossAccounts(void) {
    LCTapSyncRecovery *state = [[LCTapSyncRecovery alloc] initWithSource:@"A" targets:@[@"B", @"C", @"D"]
                                                                               reason:LCTapSyncRecoveryFollowerInput afterTime:10];
    acknowledgeAll(state);
    assert([state recordInputForContainer:@"A" revision:1 touching:YES began:YES atTime:9]);
    assert([state recordInputForContainer:@"A" revision:2 touching:NO began:NO atTime:11]);
    assert(!state.canResume); // A source gesture from before suspension cannot resume it.
    assert([state recordInputForContainer:@"B" revision:1 touching:YES began:YES atTime:20]);
    assert([state recordInputForContainer:@"A" revision:3 touching:YES began:YES atTime:30]);
    assert([state recordInputForContainer:@"A" revision:4 touching:NO began:NO atTime:31]);
    // C's begin happened before the source return but arrived later on its connection.
    assert([state recordInputForContainer:@"C" revision:1 touching:YES began:YES atTime:25]);
    assert([state recordInputForContainer:@"B" revision:2 touching:NO began:NO atTime:32]);
    assert(!state.canResume);
    assert([state recordInputForContainer:@"C" revision:2 touching:NO began:NO atTime:33]);
    assert(state.canResume);
    assert([state recordInputForContainer:@"D" revision:1 touching:YES began:YES atTime:40]);
    // An older source return cannot undo the newer follower operation either.
    assert([state recordInputForContainer:@"A" revision:5 touching:YES began:YES atTime:35]);
    assert([state recordInputForContainer:@"A" revision:6 touching:NO began:NO atTime:41]);
    assert([state recordInputForContainer:@"D" revision:2 touching:NO began:NO atTime:42]);
    assert(!state.canResume);
    assert(![state recordInputForContainer:@"A" revision:7 touching:YES began:YES atTime:NAN]);
    assert(![state recordInputForContainer:@"A" revision:7 touching:YES began:YES atTime:INFINITY]);
    assert(![state recordInputForContainer:@"A" revision:7 touching:YES began:YES atTime:-1]);
    assert([state recordInputForContainer:@"A" revision:7 touching:YES began:YES atTime:43]);
    assert([state recordInputForContainer:@"A" revision:8 touching:NO began:NO atTime:44]);
    assert(state.canResume);
}

static void testStableGeometryAndCancellation(void) {
    LCTapSyncRecovery *state = recovery(LCTapSyncRecoveryRotation);
    NSArray *portrait = @[@1, @200, @400], *landscape = @[@3, @400, @200];
    assert(![state layoutIsStable:portrait atTime:1]);
    acknowledgeAll(state);
    assert(![state layoutIsStable:portrait atTime:2]);
    assert(![state layoutIsStable:portrait atTime:2.1]);
    assert([state layoutIsStable:portrait atTime:2.25]);
    assert(![state layoutIsStable:landscape atTime:2.3]);
    assert(![state layoutIsStable:landscape atTime:2.4]);
    assert([state layoutIsStable:landscape atTime:2.55]);
    assert(![state layoutIsStable:nil atTime:2.6]);
    assert(![state layoutIsStable:landscape atTime:2.7]);
    assert(![state layoutIsStable:@[] atTime:3]);
    assert(![state layoutIsStable:landscape atTime:NAN]);
    assert(![state layoutIsStable:landscape atTime:INFINITY]);
    assert(![state layoutIsStable:landscape atTime:-1]);
    assert(![state layoutIsStable:landscape atTime:4]);
    assert(![state layoutIsStable:landscape atTime:3]); // A backwards clock restarts stability.
    assert([state layoutIsStable:landscape atTime:3.25]);
    assert([state recordInputForContainer:@"A" revision:1 touching:YES began:YES atTime:nextInputTime()]);
    assert(![state layoutIsStable:landscape atTime:4]);
    assert([state recordInputForContainer:@"A" revision:2 touching:NO began:NO atTime:nextInputTime()]);
    assert(![state layoutIsStable:landscape atTime:4.1]);
    assert([state layoutIsStable:landscape atTime:4.35]);
    [state invalidate];
    assert(!state.valid && !state.canResume && !state.pendingContainers.count);
    assert(![state acknowledgeContainer:@"A" revision:3 touching:NO]);
    assert(![state recordInputForContainer:@"A" revision:3 touching:YES began:YES atTime:nextInputTime()]);
    [state waitForSourceReturnAfter:nextInputTime()];
    assert(![state layoutIsStable:landscape atTime:5]);
}

int main(void) {
    @autoreleasepool {
        testWholeGroupIdleBarrier();
        testReturnRequiresNewSourceGesture();
        testOtherHeldFingersDelayResume();
        testReorderedRepliesAndInput();
        testRotationAndFollowerOverride();
        testReturnOrderingAcrossAccounts();
        testStableGeometryAndCancellation();
        puts("Tap sync automatic recovery tests passed");
    }
    return 0;
}
