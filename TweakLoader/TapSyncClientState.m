#import "TapSyncClientState.h"

@interface LCTapSyncClientState ()
@property(nonatomic) NSHashTable *syntheticTouches;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger recoveryAttempts;
@end

@implementation LCTapSyncClientState
- (instancetype)init {
    if ((self = [super init])) {
        // UIKit can retain a replay touch after our current-contact references clear.
        // Keep its identity without retaining it or ignoring an unrelated real touch.
        _syntheticTouches = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    return self;
}
- (void)setSession:(NSString *)session {
    _session = session.copy;
    self.generation++;
}
- (void)rememberSyntheticTouch:(id)touch { [self.syntheticTouches addObject:touch]; }
- (BOOL)ownsTouch:(id)touch { return [self.syntheticTouches containsObject:touch]; }
- (dispatch_block_t)actionForCurrentSession:(dispatch_block_t)action {
    if (!self.session) return nil;
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    return ^{
        LCTapSyncClientState *state = weakSelf;
        if (state.session && state.generation == generation) action();
    };
}
- (NSTimeInterval)nextConnectionRetryDelay {
    const NSTimeInterval delays[] = {0.25, 0.75, 1.5};
    if (self.recoveryAttempts >= sizeof(delays) / sizeof(delays[0])) return 0;
    return delays[self.recoveryAttempts++];
}
- (void)resetConnectionRecovery { self.recoveryAttempts = 0; }
@end
