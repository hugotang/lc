#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LCResourceCompactionErrorDomain;

typedef NS_ERROR_ENUM(LCResourceCompactionErrorDomain, LCResourceCompactionErrorCode) {
    LCResourceCompactionErrorUnsupportedApp = 1,
    LCResourceCompactionErrorBusy,
    LCResourceCompactionErrorInvalidContainer,
    LCResourceCompactionErrorChanged,
    LCResourceCompactionErrorUnsupportedVolume,
    LCResourceCompactionErrorCancelled,
    LCResourceCompactionErrorIO,
};

@interface LCResourceCompactionPlan : NSObject
@property(nonatomic, readonly) NSUInteger containerCount;
@property(nonatomic, readonly) NSUInteger matchingFileCount;
@property(nonatomic, readonly) NSUInteger alreadyCompactedFileCount;
@property(nonatomic, readonly) NSUInteger independentFileCount;
@property(nonatomic, readonly) int64_t candidateBytes;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface LCResourceCompactionResult : NSObject
@property(nonatomic, readonly) NSUInteger compactedFileCount;
@property(nonatomic, readonly) int64_t sharedBytes;
@property(nonatomic, readonly, nullable) NSError *stoppedError;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Replaces equal resource files with APFS clones. Paths and file contents stay
/// independent: later writes use copy-on-write, and deleting one clone leaves
/// the other intact. No download coordination or guest file hooks are involved.
@interface LCResourceCompactor : NSObject
@property(class, nonatomic, readonly) NSString *supportedBundleIdentifier;
@property(class, nonatomic, readonly) NSString *resourceRelativePath;
@property(class, nonatomic, readonly) NSString *leaseFileName;

+ (nullable LCResourceCompactionPlan *)scanContainers:(NSArray<NSURL *> *)containerURLs
                                  bundleIdentifier:(NSString *)bundleIdentifier
                                          progress:(NSProgress *)progress
                                             error:(NSError **)error
    NS_SWIFT_NAME(scan(containers:bundleIdentifier:progress:));

+ (nullable LCResourceCompactionResult *)applyPlan:(LCResourceCompactionPlan *)plan
                                        progress:(NSProgress *)progress
                                           error:(NSError **)error
    NS_SWIFT_NAME(apply(plan:progress:));

/// A guest holds this shared, nonblocking lease until process exit. Scanning
/// and replacing files hold exclusive leases on every participating container.
/// The caller owns the descriptor and must close it when the lease ends.
+ (int)acquireSharedLeaseForContainerAtURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)isCompactingContainerAtURL:(NSURL *)url NS_SWIFT_NAME(isCompactingContainer(at:));
@end

NS_ASSUME_NONNULL_END
