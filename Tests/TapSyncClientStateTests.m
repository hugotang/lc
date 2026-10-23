#import "../TweakLoader/TapSyncClientState.h"
#include <assert.h>
#include <stdio.h>

// Equal values must not make a physical contact look like an owned replay contact.
@interface EqualTouch : NSObject
@end
@implementation EqualTouch
- (BOOL)isEqual:(id)object { return [object isKindOfClass:EqualTouch.class]; }
- (NSUInteger)hash { return 1; }
@end

static void testTouchOwnershipSurvivesRestart(void) {
    LCTapSyncClientState *state = [LCTapSyncClientState new];
    EqualTouch *retainedByUIKit = [EqualTouch new];
    EqualTouch *physicalTouch = [EqualTouch new];
    assert([retainedByUIKit isEqual:physicalTouch]);
    state.session = @"old";
    [state rememberSyntheticTouch:retainedByUIKit];
    state.session = nil;
    state.session = @"new";
    assert([state ownsTouch:retainedByUIKit]);
    assert(![state ownsTouch:physicalTouch]);

    __weak NSObject *released;
    @autoreleasepool {
        NSObject *temporary = [NSObject new];
        released = temporary;
        [state rememberSyntheticTouch:temporary];
        assert([state ownsTouch:temporary]);
    }
    assert(released == nil); // The registry must not keep guest views/touches alive.
}

static void testDelayedInterruptions(void) {
    LCTapSyncClientState *state = [LCTapSyncClientState new];
    __block NSUInteger interruptions = 0;
    assert([state actionForCurrentSession:^{ interruptions++; }] == nil);

    state.session = @"old";
    dispatch_block_t oldNotification = [state actionForCurrentSession:^{ interruptions++; }];
    state.session = nil;
    oldNotification();
    assert(interruptions == 0);
    state.session = @"new";
    oldNotification();
    assert(interruptions == 0);

    dispatch_block_t currentNotification = [state actionForCurrentSession:^{ interruptions++; state.session = nil; }];
    currentNotification();
    currentNotification();
    assert(interruptions == 1 && state.session == nil);

    // Re-preparing the same identifier also invalidates old deferred work.
    state.session = @"same";
    dispatch_block_t beforePrepare = [state actionForCurrentSession:^{ interruptions++; }];
    state.session = nil;
    state.session = @"same";
    beforePrepare();
    assert(interruptions == 1);

    dispatch_block_t afterDeallocation;
    @autoreleasepool {
        LCTapSyncClientState *temporary = [LCTapSyncClientState new];
        temporary.session = @"temporary";
        afterDeallocation = [temporary actionForCurrentSession:^{ interruptions++; }];
    }
    afterDeallocation();
    assert(interruptions == 1);
}

static void testPhysicalContactIdentityAndRelease(void) {
    LCTapSyncClientState *state = [LCTapSyncClientState new];
    EqualTouch *first = [EqualTouch new], *second = [EqualTouch new], *synthetic = [EqualTouch new];
    [state rememberSyntheticTouch:synthetic];
    assert(!state.hasPhysicalTouches);
    assert(![state observePhysicalTouch:synthetic active:YES]);
    assert(!state.hasPhysicalTouches);
    assert([state observePhysicalTouch:first active:YES]);
    assert(![state observePhysicalTouch:first active:YES]); // No repeated begin for a held contact.
    assert([state observePhysicalTouch:second active:YES]);
    assert(state.hasPhysicalTouches);
    NSHashTable *returnTouches = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    [returnTouches addObject:first];
    assert([state hasPhysicalTouchesOtherThan:returnTouches]);
    [returnTouches addObject:second];
    assert(![state hasPhysicalTouchesOtherThan:returnTouches]);
    assert(![state observePhysicalTouch:synthetic active:NO]);
    assert([state observePhysicalTouch:first active:NO]);
    assert(state.hasPhysicalTouches); // Releasing an equal-valued finger leaves the other down.
    state.session = @"old";
    state.session = nil;
    state.session = @"new";
    assert(state.hasPhysicalTouches); // A fresh preparation must still reject real held fingers.
    assert([state observePhysicalTouch:second active:NO]);
    assert(![state observePhysicalTouch:second active:NO]);
    assert(!state.hasPhysicalTouches);
    assert(![state hasPhysicalTouchesOtherThan:returnTouches]);
    __weak NSObject *released;
    @autoreleasepool {
        NSObject *temporary = [NSObject new];
        released = temporary;
        assert([state observePhysicalTouch:temporary active:YES]);
        assert(state.hasPhysicalTouches);
    }
    assert(released == nil && !state.hasPhysicalTouches);
    assert([state observePhysicalTouch:first active:YES]);
    [state clearPhysicalTouches];
    assert(!state.hasPhysicalTouches); // Background cleanup does not retain a phantom down.
    assert([state ownsTouch:synthetic]);
    assert([state observePhysicalTouch:first active:YES]);
    assert([state observePhysicalTouch:first active:NO]);
}

static void testBoundedConnectionRecovery(void) {
    LCTapSyncClientState *state = [LCTapSyncClientState new];
    for (unsigned cycle = 0; cycle < 2; cycle++) {
        double totalDelay = 0;
        for (unsigned attempt = 0; attempt < 3; attempt++) {
            NSTimeInterval delay = state.nextConnectionRetryDelay;
            assert(delay > 0);
            totalDelay += delay;
        }
        assert(totalDelay <= 3);
        for (unsigned attempt = 0; attempt < 100; attempt++) assert(state.nextConnectionRetryDelay == 0);
        [state resetConnectionRecovery];
    }
}

int main(void) {
    @autoreleasepool {
        testTouchOwnershipSurvivesRestart();
        testDelayedInterruptions();
        testPhysicalContactIdentityAndRelease();
        testBoundedConnectionRecovery();
        puts("Tap sync client state tests passed");
    }
    return 0;
}
