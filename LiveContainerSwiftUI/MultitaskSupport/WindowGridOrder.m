#import "WindowGridOrder.h"

@interface LCWindowGridOrder ()
@property(nonatomic, strong) NSMutableArray *mutableWindows;
@property(nonatomic, weak) id lastSwapFirstWindow;
@property(nonatomic, weak) id lastSwapSecondWindow;
@end

@implementation LCWindowGridOrder
- (instancetype)init {
    self = [super init];
    if (self) _mutableWindows = [NSMutableArray array];
    return self;
}

- (NSArray *)windows {
    return self.mutableWindows.copy;
}

- (void)addWindow:(id)window {
    if ([self.mutableWindows indexOfObjectIdenticalTo:window] == NSNotFound) {
        [self.mutableWindows addObject:window];
    }
}

- (void)removeWindow:(id)window {
    NSUInteger index = [self.mutableWindows indexOfObjectIdenticalTo:window];
    if (index == NSNotFound) return;
    [self.mutableWindows removeObjectAtIndex:index];
    if (self.lastSwapFirstWindow == window || self.lastSwapSecondWindow == window) {
        self.lastSwapFirstWindow = nil;
        self.lastSwapSecondWindow = nil;
    }
}

- (BOOL)canSwapWindow:(id)first withWindow:(id)second visibleWindows:(NSArray *)visibleWindows {
    return first && second && first != second &&
           [self.mutableWindows indexOfObjectIdenticalTo:first] != NSNotFound &&
           [self.mutableWindows indexOfObjectIdenticalTo:second] != NSNotFound &&
           [visibleWindows indexOfObjectIdenticalTo:first] != NSNotFound &&
           [visibleWindows indexOfObjectIdenticalTo:second] != NSNotFound;
}

- (BOOL)swapWindow:(id)first withWindow:(id)second visibleWindows:(NSArray *)visibleWindows {
    if (![self canSwapWindow:first withWindow:second visibleWindows:visibleWindows]) return NO;
    [self.mutableWindows exchangeObjectAtIndex:[self.mutableWindows indexOfObjectIdenticalTo:first]
                            withObjectAtIndex:[self.mutableWindows indexOfObjectIdenticalTo:second]];
    self.lastSwapFirstWindow = first;
    self.lastSwapSecondWindow = second;
    return YES;
}

- (BOOL)canUndoSwapWithVisibleWindows:(NSArray *)visibleWindows {
    return [self canSwapWindow:self.lastSwapFirstWindow withWindow:self.lastSwapSecondWindow visibleWindows:visibleWindows];
}

- (BOOL)undoSwapWithVisibleWindows:(NSArray *)visibleWindows {
    id first = self.lastSwapFirstWindow;
    id second = self.lastSwapSecondWindow;
    if (![self canSwapWindow:first withWindow:second visibleWindows:visibleWindows]) return NO;
    [self.mutableWindows exchangeObjectAtIndex:[self.mutableWindows indexOfObjectIdenticalTo:first]
                            withObjectAtIndex:[self.mutableWindows indexOfObjectIdenticalTo:second]];
    self.lastSwapFirstWindow = nil;
    self.lastSwapSecondWindow = nil;
    return YES;
}

- (void)restoreOrderWithWindows:(NSArray *)windows {
    NSMutableArray *ordered = [NSMutableArray array];
    for (id window in windows) {
        if ([self.mutableWindows indexOfObjectIdenticalTo:window] != NSNotFound &&
            [ordered indexOfObjectIdenticalTo:window] == NSNotFound) [ordered addObject:window];
    }
    for (id window in self.mutableWindows) {
        if ([ordered indexOfObjectIdenticalTo:window] == NSNotFound) [ordered addObject:window];
    }
    self.mutableWindows = ordered;
    self.lastSwapFirstWindow = nil;
    self.lastSwapSecondWindow = nil;
}
@end
