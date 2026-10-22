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
    LCResourceCompactionErrorSharingNotRetained,
};

@interface LCResourceCompactionPlan : NSObject
@property(nonatomic, readonly) NSUInteger containerCount;
@property(nonatomic, readonly) NSUInteger matchingFileCount;
@property(nonatomic, readonly) NSUInteger alreadyCompactedFileCount;
@property(nonatomic, readonly) NSUInteger independentFileCount;
@property(nonatomic, readonly) int64_t candidateBytes;
/// Physical extent comparison, when permitted by the filesystem. These bytes
/// describe shared file data, not the change in device free space.
@property(nonatomic, readonly) NSUInteger verifiedSharedFileCount;
@property(nonatomic, readonly) int64_t verifiedSharedBytes;
@property(nonatomic, readonly) NSUInteger sharingUnavailableFileCount;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface LCResourceCompactionResult : NSObject
@property(nonatomic, readonly) NSUInteger compactedFileCount;
@property(nonatomic, readonly) int64_t processedBytes;
@property(nonatomic, readonly) NSUInteger verifiedSharedFileCount;
@property(nonatomic, readonly) NSUInteger sharingUnavailableFileCount;
@property(nonatomic, readonly, nullable) NSNumber *availableBytesBefore;
@property(nonatomic, readonly, nullable) NSNumber *availableBytesAfter;
@property(nonatomic, readonly) NSDate *completedAt;
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

/// Uses statfs available blocks, counting each volume once. No per-file size
/// summation, purgeable-space estimate or process-wide filesystem sync.
+ (nullable NSNumber *)availableBytesForContainers:(NSArray<NSURL *> *)containerURLs
    NS_SWIFT_NAME(availableBytes(containers:));
+ (nullable LCResourceCompactionResult *)lastResultForContainers:(NSArray<NSURL *> *)containerURLs
    NS_SWIFT_NAME(lastResult(containers:));

/// A guest holds this shared, nonblocking lease until process exit. Scanning
/// and replacing files hold exclusive leases on every participating container.
/// The caller owns the descriptor and must close it when the lease ends.
+ (int)acquireSharedLeaseForContainerAtURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)isCompactingContainerAtURL:(NSURL *)url NS_SWIFT_NAME(isCompactingContainer(at:));
@end

NS_ASSUME_NONNULL_END
