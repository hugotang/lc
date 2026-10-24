#import "../MultitaskSupport/DockRevealControl.h"

// Test-only event trace: UI tests can retrieve it after a failing swipe without
// changing the production recognizer or depending on simulator console logs.
@interface LCDockDiagnosticHideGesture : LCDockHideGesture
@property(nonatomic, readonly) NSString *traceSummary;
@end
