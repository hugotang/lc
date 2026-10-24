#import "DockGestureDiagnostics.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

@interface LCDockDiagnosticHideGesture ()
@property(nonatomic) NSMutableString *trace;
@end

@implementation LCDockDiagnosticHideGesture
- (NSString *)traceSummary { return self.trace ?: @"No Dock gesture events"; }
- (void)record:(NSString *)label touch:(UITouch *)touch {
    if (!self.trace) self.trace = [NSMutableString new];
    CGPoint point = touch ? [touch locationInView:self.view] : CGPointZero;
    [self.trace appendFormat:@"%@(%g,%g) state=%ld; ", label, point.x, point.y, (long)self.state];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    BOOL accepted = [super gestureRecognizer:gesture shouldReceiveTouch:touch];
    self.trace = [NSMutableString new];
    [self record:accepted ? @"receive YES" : @"receive NO" touch:touch];
    for (UIView *view = touch.view; view; view = view.superview) {
        [self.trace appendFormat:@"%@ -> ", NSStringFromClass(view.class)];
    }
    return accepted;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    BOOL accepted = [super gestureRecognizerShouldBegin:gesture];
    [self record:accepted ? @"begin YES" : @"begin NO" touch:nil];
    return accepted;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {
    BOOL prevented = [super canBePreventedByGestureRecognizer:other];
    [self record:[NSString stringWithFormat:@"prevent %@=%d", NSStringFromClass(other.class), prevented] touch:nil];
    return prevented;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self record:@"down" touch:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    [self record:@"move" touch:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self record:@"up" touch:touches.anyObject];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self record:@"cancel" touch:touches.anyObject];
}
@end
