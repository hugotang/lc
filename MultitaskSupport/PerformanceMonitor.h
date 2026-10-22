#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const LCPerformanceDidChangeNotification;

API_AVAILABLE(ios(16.0))
@interface LCPerformanceMonitor : NSObject
@property(class, nonatomic, readonly) LCPerformanceMonitor *shared;
@property(nonatomic, weak, nullable) UIView *hostView;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isSampling) BOOL sampling;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *snapshot;
@property(nonatomic, copy, readonly) NSString *csvReport;
- (void)updateVisibility;
- (void)resetMeasurements;
@end
NS_ASSUME_NONNULL_END
