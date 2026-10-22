#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reduces completed foreground sampling rounds. All calls use the host's main queue.
@interface LCPerformanceRecording : NSObject
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *snapshot;
@property(nonatomic, readonly) NSUInteger sampleCount;
- (void)resetAtTime:(NSTimeInterval)time;
- (void)suspend;
// Returns YES when a different process set or sync epoch starts a new segment.
// An unfinished round must be discarded when this returns YES.
- (BOOL)prepareForProcesses:(NSDictionary<NSString *, NSDictionary *> *)processes
                      sync:(NSDictionary *)sync atTime:(NSTimeInterval)time;
- (void)recordSamples:(NSDictionary<NSString *, NSDictionary *> *)samples
                sync:(NSDictionary *)sync atTime:(NSTimeInterval)time
        thermalState:(NSInteger)thermalState lowPowerMode:(BOOL)lowPowerMode
                 now:(NSTimeInterval)now;
- (NSString *)csvReportWithMetadata:(NSDictionary<NSString *, id> *)metadata;
@end

NS_ASSUME_NONNULL_END
