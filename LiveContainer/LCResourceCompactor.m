#import "LCResourceCompactor.h"
#import <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

NSErrorDomain const LCResourceCompactionErrorDomain = @"LCResourceCompactionErrorDomain";
static NSString *const LCManifestName = @".lc-resource-compaction.plist";
static NSString *const LCReportName = @".lc-resource-compaction-report.plist";
static NSInteger const LCManifestVersion = 2;

static NSError *LCError(LCResourceCompactionErrorCode code, NSString *detail) {
    return [NSError errorWithDomain:LCResourceCompactionErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: detail ?: @"Resource compaction failed."}];
}

static BOOL LCFail(NSError **error, LCResourceCompactionErrorCode code, NSString *detail) {
    if (error) *error = LCError(code, detail);
    return NO;
}

static BOOL LCCancelled(NSProgress *progress, NSError **error) {
    if (!progress.cancelled) return NO;
    LCFail(error, LCResourceCompactionErrorCancelled, @"Resource compaction was cancelled.");
    return YES;
}

static BOOL LCSameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_nlink == b.st_nlink && a.st_mode == b.st_mode &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}

static NSDictionary *LCIdentity(struct stat value) {
    return @{@"device": @((uint64_t)value.st_dev), @"inode": @((uint64_t)value.st_ino),
             @"size": @((int64_t)value.st_size), @"links": @((uint64_t)value.st_nlink),
             @"mode": @((uint64_t)value.st_mode),
             @"mtime": @((int64_t)value.st_mtimespec.tv_sec), @"mtimeNS": @(value.st_mtimespec.tv_nsec),
             @"ctime": @((int64_t)value.st_ctimespec.tv_sec), @"ctimeNS": @(value.st_ctimespec.tv_nsec)};
}

static BOOL LCRegularPrivateFile(struct stat value) {
    return S_ISREG(value.st_mode) && value.st_nlink == 1 && value.st_size > 0;
}

static NSData *LCDigest(int descriptor, NSProgress *progress, NSError **error) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        LCFail(error, LCResourceCompactionErrorIO, @"Unable to seek a resource file.");
        return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[256 * 1024];
    for (;;) {
        if (LCCancelled(progress, error)) return nil;
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            LCFail(error, LCResourceCompactionErrorIO, @"Unable to read a resource file.");
            return nil;
        }
        if (count == 0) break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        progress.completedUnitCount += count;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

/// Compare complete extent maps rather than st_blocks, which counts cloned
/// blocks for each inode. Sandboxes/filesystems may deny these queries; nil
/// means unavailable, never zero sharing. No physical offsets leave this code.
static NSNumber *LCSharedDataBytes(int sourceFD, int targetFD, off_t size, NSProgress *progress) {
    int64_t shared = 0;
    for (off_t offset = 0; offset < size;) {
        if (progress.cancelled) return nil;
        struct log2phys source = { .l2p_contigbytes = size - offset, .l2p_devoffset = offset };
        struct log2phys target = { .l2p_contigbytes = size - offset, .l2p_devoffset = offset };
        if (fcntl(sourceFD, F_LOG2PHYS_EXT, &source) || fcntl(targetFD, F_LOG2PHYS_EXT, &target) ||
            source.l2p_devoffset < 0 || target.l2p_devoffset < 0 ||
            source.l2p_contigbytes <= 0 || target.l2p_contigbytes <= 0) return nil;
        off_t length = MIN(size - offset, MIN(source.l2p_contigbytes, target.l2p_contigbytes));
        if (source.l2p_devoffset == target.l2p_devoffset) shared += length;
        offset += length;
    }
    return @(shared);
}

@interface LCResourceFile : NSObject
@property(nonatomic) NSURL *containerURL;
@property(nonatomic) NSURL *url;
@property(nonatomic) NSString *name;
@property(nonatomic) NSData *digest;
@property(nonatomic) struct stat identity;
@end
@implementation LCResourceFile
@end

@interface LCResourceReplacement : NSObject
@property(nonatomic) LCResourceFile *source;
@property(nonatomic) LCResourceFile *target;
@end
@implementation LCResourceReplacement
@end

static NSNumber *LCExistingSharedBytes(LCResourceFile *source, LCResourceFile *target,
                                       NSProgress *progress, NSError **error) {
    int sourceFD = open(source.url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    int targetFD = open(target.url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat a, b;
    NSNumber *shared = nil;
    if (sourceFD < 0 || targetFD < 0 || fstat(sourceFD, &a) || fstat(targetFD, &b) ||
        !LCSameFile(a, source.identity) || !LCSameFile(b, target.identity)) {
        LCFail(error, LCResourceCompactionErrorChanged, @"A resource changed during the sharing check. Analyze again.");
    } else {
        shared = LCSharedDataBytes(sourceFD, targetFD, target.identity.st_size, progress);
        if (LCCancelled(progress, error)) {
            shared = nil;
        } else if (fstat(sourceFD, &a) || fstat(targetFD, &b) ||
                   !LCSameFile(a, source.identity) || !LCSameFile(b, target.identity)) {
            LCFail(error, LCResourceCompactionErrorChanged, @"A resource changed during the sharing check. Analyze again.");
            shared = nil;
        }
    }
    if (sourceFD >= 0) close(sourceFD);
    if (targetFD >= 0) close(targetFD);
    return shared;
}

@interface LCResourceCompactionPlan ()
@property(nonatomic, readwrite) NSUInteger containerCount;
@property(nonatomic, readwrite) NSUInteger matchingFileCount;
@property(nonatomic, readwrite) NSUInteger alreadyCompactedFileCount;
@property(nonatomic, readwrite) NSUInteger independentFileCount;
@property(nonatomic, readwrite) int64_t candidateBytes;
@property(nonatomic, readwrite) NSUInteger verifiedSharedFileCount;
@property(nonatomic, readwrite) int64_t verifiedSharedBytes;
@property(nonatomic, readwrite) NSUInteger sharingUnavailableFileCount;
@property(nonatomic) NSArray<NSURL *> *containerURLs;
@property(nonatomic) NSArray<LCResourceReplacement *> *replacements;
- (instancetype)initInternal;
@end
@implementation LCResourceCompactionPlan
- (instancetype)initInternal { return [super init]; }
@end

@interface LCResourceCompactionResult ()
@property(nonatomic, readwrite) NSUInteger compactedFileCount;
@property(nonatomic, readwrite) int64_t processedBytes;
@property(nonatomic, readwrite) NSUInteger verifiedSharedFileCount;
@property(nonatomic, readwrite) NSUInteger sharingUnavailableFileCount;
@property(nonatomic, readwrite, nullable) NSNumber *availableBytesBefore;
@property(nonatomic, readwrite, nullable) NSNumber *availableBytesAfter;
@property(nonatomic, readwrite) NSDate *completedAt;
@property(nonatomic, readwrite, nullable) NSError *stoppedError;
- (instancetype)initInternal;
@end
@implementation LCResourceCompactionResult
- (instancetype)initInternal { return [super init]; }
@end

/// Descriptor-relative replacement prevents a renamed/symlinked resource
/// directory from redirecting writes elsewhere in the container.
static BOOL LCReplace(LCResourceReplacement *replacement, NSProgress *progress, NSError **error,
                      NSDictionary **manifestRecord, BOOL *sharingVerified) {
    LCResourceFile *source = replacement.source, *target = replacement.target;
    int sourceFD = -1, targetFD = -1, directoryFD = -1, cloneFD = -1;
    NSString *temporaryName = [@".lc-resource-clone-" stringByAppendingString:NSUUID.UUID.UUIDString];
    BOOL createdClone = NO, succeeded = NO;
    struct stat sourceStat, targetStat, namedTarget, clonedStat;

    sourceFD = open(source.url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    directoryFD = open(target.url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (sourceFD < 0 || directoryFD < 0) {
        LCFail(error, LCResourceCompactionErrorChanged, @"A resource file or directory is no longer available.");
        goto cleanup;
    }
    targetFD = openat(directoryFD, target.name.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (targetFD < 0 || fstat(sourceFD, &sourceStat) || fstat(targetFD, &targetStat) ||
        !LCSameFile(sourceStat, source.identity) || !LCSameFile(targetStat, target.identity)) {
        LCFail(error, LCResourceCompactionErrorChanged, @"Resource files changed after analysis. Analyze again.");
        goto cleanup;
    }
    if (LCCancelled(progress, error)) goto cleanup;
    if (fclonefileat(sourceFD, directoryFD, temporaryName.UTF8String, CLONE_NOOWNERCOPY)) {
        LCResourceCompactionErrorCode code = (errno == ENOTSUP || errno == EXDEV || errno == EINVAL)
            ? LCResourceCompactionErrorUnsupportedVolume : LCResourceCompactionErrorIO;
        LCFail(error, code, @"Unable to create an APFS clone. The original resource file was preserved.");
        goto cleanup;
    }
    createdClone = YES;
    // Metadata operations accept a read-only descriptor. Opening a clone for
    // writing can have filesystem side effects despite never writing its data.
    cloneFD = openat(directoryFD, temporaryName.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (cloneFD < 0 || fstat(cloneFD, &clonedStat) || !LCRegularPrivateFile(clonedStat) ||
        clonedStat.st_ino == sourceStat.st_ino || clonedStat.st_size != targetStat.st_size) {
        LCFail(error, LCResourceCompactionErrorIO, @"Unable to verify the cloned file.");
        goto cleanup;
    }
    {
        NSData *cloneHash = LCDigest(cloneFD, progress, error);
        if (!cloneHash) goto cleanup;
        NSData *targetHash = LCDigest(targetFD, progress, error);
        if (!targetHash) goto cleanup;
        if (![cloneHash isEqual:source.digest] || ![targetHash isEqual:target.digest] ||
            ![cloneHash isEqual:targetHash]) {
            LCFail(error, LCResourceCompactionErrorChanged, @"A resource file changed during verification.");
            goto cleanup;
        }
    }
    // A clone inherits source metadata. Restore the TARGET's permissions, ACLs,
    // extended attributes and modification time, then verify iOS protection.
    if (fcopyfile(targetFD, cloneFD, NULL, COPYFILE_METADATA)) {
        LCFail(error, LCResourceCompactionErrorIO, @"Unable to preserve resource metadata. The original file was preserved.");
        goto cleanup;
    }
#if TARGET_OS_IPHONE
    {
        int targetProtection = fcntl(targetFD, F_GETPROTECTIONCLASS);
        int cloneProtection = fcntl(cloneFD, F_GETPROTECTIONCLASS);
        if (targetProtection < 0 || cloneProtection < 0 ||
            (targetProtection != cloneProtection && fcntl(cloneFD, F_SETPROTECTIONCLASS, targetProtection)) ||
            fcntl(cloneFD, F_GETPROTECTIONCLASS) != targetProtection) {
            LCFail(error, LCResourceCompactionErrorIO, @"Unable to preserve the target's file protection class.");
            goto cleanup;
        }
    }
#endif
    if (fsync(cloneFD)) {
        LCFail(error, LCResourceCompactionErrorIO, @"Unable to sync resource metadata. The original file was preserved.");
        goto cleanup;
    }
    {
        NSNumber *shared = LCSharedDataBytes(sourceFD, cloneFD, targetStat.st_size, progress);
        if (shared && shared.longLongValue != targetStat.st_size) {
            LCFail(error, LCResourceCompactionErrorSharingNotRetained,
                   @"The cloned resource did not retain shared data blocks. The original file was preserved.");
            goto cleanup;
        }
        *sharingVerified = shared != nil;
    }
    if (LCCancelled(progress, error)) goto cleanup;
    if (fstat(sourceFD, &sourceStat) || fstat(targetFD, &targetStat) ||
        fstatat(directoryFD, target.name.UTF8String, &namedTarget, AT_SYMLINK_NOFOLLOW) ||
        !LCSameFile(sourceStat, source.identity) || !LCSameFile(targetStat, target.identity) ||
        !LCSameFile(namedTarget, target.identity)) {
        LCFail(error, LCResourceCompactionErrorChanged, @"A resource file changed during replacement.");
        goto cleanup;
    }
    if (renameat(directoryFD, temporaryName.UTF8String, directoryFD, target.name.UTF8String)) {
        LCFail(error, LCResourceCompactionErrorIO, @"Unable to replace a resource file. The original file was preserved.");
        goto cleanup;
    }
    createdClone = NO;
    succeeded = YES;
    // Losing the advisory manifest on a crash only causes a later re-scan.
    // The file's data was synced before its atomic replacement.
    if (!fstat(cloneFD, &clonedStat)) {
        target.identity = clonedStat;
        *manifestRecord = @{@"sourceContainer": source.containerURL.lastPathComponent,
                            @"source": LCIdentity(sourceStat), @"target": LCIdentity(clonedStat),
                            @"digest": source.digest};
    }

cleanup:
    if (createdClone) unlinkat(directoryFD, temporaryName.UTF8String, 0);
    if (cloneFD >= 0) close(cloneFD);
    if (targetFD >= 0) close(targetFD);
    if (sourceFD >= 0) close(sourceFD);
    if (directoryFD >= 0) close(directoryFD);
    return succeeded;
}

@implementation LCResourceCompactor
+ (NSString *)supportedBundleIdentifier { return @"jp.co.mixi.monsterstrike"; }
+ (NSString *)resourceRelativePath { return @"Library/Application Support/dl_res"; }
+ (NSString *)leaseFileName { return @".lc-resource-compaction.lock"; }

+ (nullable NSNumber *)availableBytesForContainers:(NSArray<NSURL *> *)containerURLs {
    if (!containerURLs.count) return nil;
    NSMutableSet<NSNumber *> *devices = [NSMutableSet set];
    uint64_t total = 0;
    for (NSURL *url in containerURLs) {
        struct stat value;
        struct statfs filesystem;
        if (!url.isFileURL || stat(url.fileSystemRepresentation, &value) ||
            statfs(url.fileSystemRepresentation, &filesystem) || filesystem.f_bsize == 0) return nil;
        NSNumber *device = @((uint64_t)value.st_dev);
        if ([devices containsObject:device]) continue;
        [devices addObject:device];
        uint64_t blockSize = filesystem.f_bsize, availableBlocks = filesystem.f_bavail;
        if (availableBlocks > ((uint64_t)INT64_MAX - total) / blockSize) return nil;
        total += availableBlocks * blockSize;
    }
    return @((int64_t)total);
}

+ (NSArray<NSString *> *)reportPathsForContainers:(NSArray<NSURL *> *)containerURLs {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in containerURLs) {
        if (!url.isFileURL) return @[];
        [paths addObject:url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path];
    }
    return [paths sortedArrayUsingSelector:@selector(compare:)];
}

+ (nullable LCResourceCompactionResult *)lastResultForContainers:(NSArray<NSURL *> *)containerURLs {
    NSArray<NSString *> *paths = [self reportPathsForContainers:containerURLs];
    if (!paths.count) return nil;
    LCResourceCompactionResult *latest = nil;
    for (NSURL *containerURL in containerURLs) {
        NSURL *url = [containerURL URLByAppendingPathComponent:LCReportName];
        struct stat value;
        if (lstat(url.fileSystemRepresentation, &value) || !S_ISREG(value.st_mode) ||
            value.st_nlink != 1 || value.st_size > 64 * 1024) continue;
        NSDictionary *report = [NSDictionary dictionaryWithContentsOfURL:url];
        if (![report[@"version"] isEqual:@1] || ![report[@"containers"] isEqual:paths] ||
            ![report[@"completedAt"] isKindOfClass:NSDate.class] ||
            ![report[@"compactedFiles"] isKindOfClass:NSNumber.class] ||
            ![report[@"processedBytes"] isKindOfClass:NSNumber.class] ||
            ![report[@"verifiedSharedFiles"] isKindOfClass:NSNumber.class] ||
            ![report[@"sharingUnavailableFiles"] isKindOfClass:NSNumber.class]) continue;
        LCResourceCompactionResult *result = [[LCResourceCompactionResult alloc] initInternal];
        result.compactedFileCount = [report[@"compactedFiles"] unsignedIntegerValue];
        result.processedBytes = [report[@"processedBytes"] longLongValue];
        result.verifiedSharedFileCount = [report[@"verifiedSharedFiles"] unsignedIntegerValue];
        result.sharingUnavailableFileCount = [report[@"sharingUnavailableFiles"] unsignedIntegerValue];
        result.completedAt = report[@"completedAt"];
        if ([report[@"availableBefore"] isKindOfClass:NSNumber.class]) result.availableBytesBefore = report[@"availableBefore"];
        if ([report[@"availableAfter"] isKindOfClass:NSNumber.class]) result.availableBytesAfter = report[@"availableAfter"];
        NSNumber *stoppedCode = report[@"stoppedCode"];
        if ([stoppedCode isKindOfClass:NSNumber.class] && stoppedCode.integerValue > 0 &&
            stoppedCode.integerValue <= LCResourceCompactionErrorSharingNotRetained) {
            result.stoppedError = LCError(stoppedCode.integerValue, @"Resource compaction stopped before completion.");
        }
        if (!latest || [result.completedAt compare:latest.completedAt] == NSOrderedDescending) latest = result;
    }
    return latest;
}

+ (void)saveResult:(LCResourceCompactionResult *)result containers:(NSArray<NSURL *> *)containerURLs {
    NSMutableDictionary *report = [@{@"version": @1, @"containers": [self reportPathsForContainers:containerURLs],
        @"completedAt": result.completedAt, @"compactedFiles": @(result.compactedFileCount),
        @"processedBytes": @(result.processedBytes), @"verifiedSharedFiles": @(result.verifiedSharedFileCount),
        @"sharingUnavailableFiles": @(result.sharingUnavailableFileCount)} mutableCopy];
    if (result.availableBytesBefore) report[@"availableBefore"] = result.availableBytesBefore;
    if (result.availableBytesAfter) report[@"availableAfter"] = result.availableBytesAfter;
    if (result.stoppedError) report[@"stoppedCode"] = @(result.stoppedError.code);
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:report format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    for (NSURL *url in containerURLs) {
        [data writeToURL:[url URLByAppendingPathComponent:LCReportName] options:NSDataWritingAtomic error:nil];
    }
}

+ (int)acquireLease:(NSURL *)url exclusive:(BOOL)exclusive create:(BOOL)create error:(NSError **)error {
    int directoryFD = open(url.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryFD < 0) {
        LCFail(error, LCResourceCompactionErrorInvalidContainer, @"The container directory is unavailable.");
        return -1;
    }
    int descriptor = openat(directoryFD, self.leaseFileName.UTF8String,
                            O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
    int openError = errno;
    close(directoryFD);
    if (descriptor < 0) {
        LCFail(error, LCResourceCompactionErrorIO, [NSString stringWithFormat:@"Unable to open the container lease (%d).", openError]);
        return -1;
    }
    struct stat value;
    if (fstat(descriptor, &value) || !S_ISREG(value.st_mode) || value.st_nlink != 1) {
        close(descriptor);
        LCFail(error, LCResourceCompactionErrorInvalidContainer, @"The container lease is not a regular private file.");
        return -1;
    }
#if TARGET_OS_IPHONE
    // This lease has no buffered account data and is safe to keep across guest
    // suspension. Use the existing Dead10ccFix convention for shared storage.
    unsigned char suspendSafe = 1;
    fsetxattr(descriptor, "com.apple.runningboard.can-suspend-locked", &suspendSafe, sizeof(suspendSafe), 0, 0);
#endif
    if (flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB)) {
        close(descriptor);
        LCFail(error, LCResourceCompactionErrorBusy, @"Close all participating game windows and try again.");
        return -1;
    }
    return descriptor;
}

+ (int)acquireSharedLeaseForContainerAtURL:(NSURL *)url error:(NSError **)error {
    return [self acquireLease:url exclusive:NO create:YES error:error];
}

+ (BOOL)isCompactingContainerAtURL:(NSURL *)url {
    NSError *error;
    int descriptor = [self acquireLease:url exclusive:NO create:NO error:&error];
    if (descriptor >= 0) close(descriptor);
    return error.code == LCResourceCompactionErrorBusy && [error.domain isEqualToString:LCResourceCompactionErrorDomain];
}

+ (BOOL)validateContainer:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) return LCFail(error, LCResourceCompactionErrorInvalidContainer, @"A local container is required.");
    struct stat rootStat;
    if (lstat(url.fileSystemRepresentation, &rootStat) || !S_ISDIR(rootStat.st_mode)) {
        return LCFail(error, LCResourceCompactionErrorInvalidContainer, @"A regular container directory is required.");
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"LCContainerInfo.plist"]];
    if (![info[@"appIdentifier"] isEqual:self.supportedBundleIdentifier]) {
        return LCFail(error, LCResourceCompactionErrorUnsupportedApp, @"This prototype supports the supplied Japanese Monster Strike app only.");
    }
    struct statfs filesystem;
    if (statfs(url.fileSystemRepresentation, &filesystem) || strcmp(filesystem.f_fstypename, "apfs")) {
        return LCFail(error, LCResourceCompactionErrorUnsupportedVolume, @"APFS storage on the same volume is required.");
    }
    NSURL *directory = url;
    for (NSString *part in [self.resourceRelativePath componentsSeparatedByString:@"/"]) {
        directory = [directory URLByAppendingPathComponent:part];
        struct stat value;
        if (lstat(directory.fileSystemRepresentation, &value) || !S_ISDIR(value.st_mode) || value.st_dev != rootStat.st_dev) {
            return LCFail(error, LCResourceCompactionErrorInvalidContainer, @"Download resources must be regular directories inside the container.");
        }
    }
    return YES;
}

+ (nullable NSArray<NSNumber *> *)lockContainers:(NSArray<NSURL *> *)urls error:(NSError **)error {
    NSMutableArray<NSNumber *> *descriptors = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (![self validateContainer:url error:error]) break;
        int descriptor = [self acquireLease:url exclusive:YES create:YES error:error];
        if (descriptor < 0) break;
        [descriptors addObject:@(descriptor)];
    }
    if (descriptors.count == urls.count) return descriptors;
    for (NSNumber *descriptor in descriptors) close(descriptor.intValue);
    return nil;
}

+ (NSDictionary *)manifestForContainer:(NSURL *)url {
    NSURL *manifestURL = [url URLByAppendingPathComponent:LCManifestName];
    struct stat value;
    if (lstat(manifestURL.fileSystemRepresentation, &value) || !S_ISREG(value.st_mode) ||
        value.st_nlink != 1 || value.st_size > 2 * 1024 * 1024) return @{};
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    // Version 1 recorded replacements before physical-sharing diagnostics and
    // used a writable clone descriptor. Re-evaluate those files once.
    if (![manifest[@"version"] isEqual:@(LCManifestVersion)] || ![manifest[@"files"] isKindOfClass:NSDictionary.class]) return @{};
    return manifest[@"files"];
}

+ (BOOL)eligibleName:(NSString *)name {
    if (![name hasPrefix:@"data"] || ![name hasSuffix:@".bin"] || name.length <= 8 ||
        [@[@"data12.bin", @"data17.bin"] containsObject:name]) return NO;
    NSString *digits = [name substringWithRange:NSMakeRange(4, name.length - 8)];
    return [digits rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

+ (nullable LCResourceCompactionPlan *)scanContainers:(NSArray<NSURL *> *)containerURLs
                                  bundleIdentifier:(NSString *)bundleIdentifier progress:(NSProgress *)progress
                                             error:(NSError **)error {
    if (![bundleIdentifier isEqual:self.supportedBundleIdentifier]) {
        LCFail(error, LCResourceCompactionErrorUnsupportedApp, @"This game is not supported by resource compaction.");
        return nil;
    }
    if (containerURLs.count < 2 || containerURLs.count > 128) {
        LCFail(error, LCResourceCompactionErrorInvalidContainer, @"At least two different containers are required.");
        return nil;
    }
    if (LCCancelled(progress, error)) return nil;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *url in containerURLs) {
        if (![self validateContainer:url error:error]) return nil;
        NSURL *canonical = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
        for (NSString *path in seen) {
            if ([path isEqual:canonical.path] || [path hasPrefix:[canonical.path stringByAppendingString:@"/"]] ||
                [canonical.path hasPrefix:[path stringByAppendingString:@"/"]]) {
                LCFail(error, LCResourceCompactionErrorInvalidContainer, @"Containers must have separate, nonoverlapping directories.");
                return nil;
            }
        }
        [seen addObject:canonical.path];
        [urls addObject:canonical];
    }
    [urls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
    NSArray<NSNumber *> *leases = [self lockContainers:urls error:error];
    if (!leases) return nil;
    LCResourceCompactionPlan *plan = [[LCResourceCompactionPlan alloc] initInternal];
    plan.containerCount = urls.count;
    plan.containerURLs = urls;
    NSMutableArray<LCResourceFile *> *files = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *manifests = [NSMutableDictionary dictionary];
    @try {
        for (NSURL *url in urls) {
            manifests[url.path] = [self manifestForContainer:url];
            NSURL *resourceURL = [url URLByAppendingPathComponent:self.resourceRelativePath];
            NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:resourceURL
                                                                   includingPropertiesForKeys:nil options:0 error:error];
            if (!contents) return nil;
            for (NSURL *fileURL in contents) {
                struct stat value;
                if (lstat(fileURL.fileSystemRepresentation, &value)) {
                    LCFail(error, LCResourceCompactionErrorChanged, @"Resources changed while being listed.");
                    return nil;
                }
                if (![self eligibleName:fileURL.lastPathComponent] || !LCRegularPrivateFile(value)) {
                    plan.independentFileCount++;
                    continue;
                }
                LCResourceFile *file = [LCResourceFile new];
                file.containerURL = url;
                file.url = fileURL;
                file.name = fileURL.lastPathComponent;
                file.identity = value;
                [files addObject:file];
            }
        }
        [files sortUsingComparator:^NSComparisonResult(LCResourceFile *a, LCResourceFile *b) {
            NSComparisonResult order = [a.name compare:b.name];
            return order == NSOrderedSame ? [a.containerURL.path compare:b.containerURL.path] : order;
        }];
        progress.totalUnitCount = 0;
        for (LCResourceFile *file in files) progress.totalUnitCount += file.identity.st_size;
        progress.completedUnitCount = 0;
        NSMutableDictionary<NSString *, LCResourceFile *> *sources = [NSMutableDictionary dictionary];
        NSMutableArray<LCResourceReplacement *> *replacements = [NSMutableArray array];
        for (LCResourceFile *file in files) {
            if (LCCancelled(progress, error)) return nil;
            int descriptor = open(file.url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            struct stat before, after;
            unsigned char signature[4];
            if (descriptor < 0 || fstat(descriptor, &before) || !LCSameFile(before, file.identity) ||
                read(descriptor, signature, sizeof(signature)) != (ssize_t)sizeof(signature)) {
                if (descriptor >= 0) close(descriptor);
                LCFail(error, LCResourceCompactionErrorChanged, @"A resource file changed during analysis.");
                return nil;
            }
            if (memcmp(signature, "OggS", 4) && memcmp(signature, "PK\x03\x04", 4)) {
                progress.completedUnitCount += before.st_size;
                close(descriptor);
                plan.independentFileCount++;
                continue;
            }
            file.digest = LCDigest(descriptor, progress, error);
            BOOL stable = !fstat(descriptor, &after) && LCSameFile(before, after);
            close(descriptor);
            if (!file.digest) return nil;
            if (!stable) {
                LCFail(error, LCResourceCompactionErrorChanged, @"A resource file changed during analysis.");
                return nil;
            }
            NSString *group = [NSString stringWithFormat:@"%@:%llu:%@", file.name,
                               (unsigned long long)file.identity.st_dev, [file.digest base64EncodedStringWithOptions:0]];
            LCResourceFile *source = sources[group];
            if (!source) {
                sources[group] = file;
                continue;
            }
            NSError *sharingError = nil;
            NSNumber *shared = LCExistingSharedBytes(source, file, progress, &sharingError);
            if (sharingError) {
                if (error) *error = sharingError;
                return nil;
            }
            if (shared) {
                plan.verifiedSharedBytes += shared.longLongValue;
                if (shared.longLongValue == file.identity.st_size) {
                    plan.verifiedSharedFileCount++;
                    plan.alreadyCompactedFileCount++;
                    continue;
                }
            } else {
                plan.sharingUnavailableFileCount++;
            }
            NSDictionary *record = manifests[file.containerURL.path][file.name];
            if (!shared && [record isKindOfClass:NSDictionary.class] &&
                [record[@"sourceContainer"] isEqual:source.containerURL.lastPathComponent] &&
                [record[@"source"] isEqual:LCIdentity(source.identity)] &&
                [record[@"target"] isEqual:LCIdentity(file.identity)] && [record[@"digest"] isEqual:file.digest]) {
                plan.alreadyCompactedFileCount++;
                continue;
            }
            LCResourceReplacement *replacement = [LCResourceReplacement new];
            replacement.source = source;
            replacement.target = file;
            [replacements addObject:replacement];
            plan.candidateBytes += file.identity.st_size;
        }
        plan.replacements = replacements;
        plan.matchingFileCount = replacements.count;
        return plan;
    } @finally {
        for (NSNumber *descriptor in leases) close(descriptor.intValue);
    }
}

+ (nullable LCResourceCompactionResult *)applyPlan:(LCResourceCompactionPlan *)plan progress:(NSProgress *)progress
                                           error:(NSError **)error {
    if (LCCancelled(progress, error)) return nil;
    NSArray<NSNumber *> *leases = [self lockContainers:plan.containerURLs error:error];
    if (!leases) return nil;
    LCResourceCompactionResult *result = [[LCResourceCompactionResult alloc] initInternal];
    result.availableBytesBefore = [self availableBytesForContainers:plan.containerURLs];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *manifests = [NSMutableDictionary dictionary];
    NSError *failure = nil;
    @try {
        progress.totalUnitCount = plan.candidateBytes * 2;
        progress.completedUnitCount = 0;
        for (LCResourceReplacement *replacement in plan.replacements) {
            @autoreleasepool {
                if (LCCancelled(progress, &failure)) break;
                if (![self validateContainer:replacement.source.containerURL error:&failure] ||
                    ![self validateContainer:replacement.target.containerURL error:&failure]) break;
                NSDictionary *record = nil;
                BOOL sharingVerified = NO;
                if (!LCReplace(replacement, progress, &failure, &record, &sharingVerified)) break;
                result.compactedFileCount++;
                result.processedBytes += replacement.target.identity.st_size;
                if (sharingVerified) result.verifiedSharedFileCount++;
                else result.sharingUnavailableFileCount++;
                NSString *key = replacement.target.containerURL.path;
                if (record) {
                    if (!manifests[key]) manifests[key] = [[self manifestForContainer:replacement.target.containerURL] mutableCopy];
                    manifests[key][replacement.target.name] = record;
                }
            }
        }
        for (NSString *path in manifests) {
            NSURL *url = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:LCManifestName];
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version": @(LCManifestVersion), @"files": manifests[path]}
                                                                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            // The marker is advisory, never trusted for content verification.
            // A failed write cannot invalidate an already verified clone.
            [data writeToURL:url options:NSDataWritingAtomic error:nil];
        }
        result.availableBytesAfter = [self availableBytesForContainers:plan.containerURLs];
        result.completedAt = NSDate.date;
        result.stoppedError = failure;
        if (!failure || result.compactedFileCount > 0) [self saveResult:result containers:plan.containerURLs];
    } @finally {
        for (NSNumber *descriptor in leases) close(descriptor.intValue);
    }
    if (failure && result.compactedFileCount == 0) {
        if (error) *error = failure;
        return nil;
    }
    result.stoppedError = failure;
    return result;
}
@end
