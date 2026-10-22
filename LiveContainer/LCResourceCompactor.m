#import "LCResourceCompactor.h"
#import <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
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

@interface LCResourceCompactionPlan ()
@property(nonatomic, readwrite) NSUInteger containerCount;
@property(nonatomic, readwrite) NSUInteger matchingFileCount;
@property(nonatomic, readwrite) NSUInteger alreadyCompactedFileCount;
@property(nonatomic, readwrite) NSUInteger independentFileCount;
@property(nonatomic, readwrite) int64_t candidateBytes;
@property(nonatomic) NSArray<NSURL *> *containerURLs;
@property(nonatomic) NSArray<LCResourceReplacement *> *replacements;
- (instancetype)initInternal;
@end
@implementation LCResourceCompactionPlan
- (instancetype)initInternal { return [super init]; }
@end

@interface LCResourceCompactionResult ()
@property(nonatomic, readwrite) NSUInteger compactedFileCount;
@property(nonatomic, readwrite) int64_t sharedBytes;
@property(nonatomic, readwrite, nullable) NSError *stoppedError;
- (instancetype)initInternal;
@end
@implementation LCResourceCompactionResult
- (instancetype)initInternal { return [super init]; }
@end

/// Descriptor-relative replacement prevents a renamed/symlinked resource
/// directory from redirecting writes elsewhere in the container.
static BOOL LCReplace(LCResourceReplacement *replacement, NSProgress *progress, NSError **error,
                      NSDictionary **manifestRecord) {
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
    cloneFD = openat(directoryFD, temporaryName.UTF8String, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
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
    if (fcopyfile(targetFD, cloneFD, NULL, COPYFILE_METADATA) || fsync(cloneFD)) {
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
    if (![manifest[@"version"] isEqual:@1] || ![manifest[@"files"] isKindOfClass:NSDictionary.class]) return @{};
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
            NSDictionary *record = manifests[file.containerURL.path][file.name];
            if ([record isKindOfClass:NSDictionary.class] &&
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
    NSMutableDictionary<NSString *, NSMutableDictionary *> *manifests = [NSMutableDictionary dictionary];
    NSError *failure;
    @try {
        progress.totalUnitCount = plan.candidateBytes * 2;
        progress.completedUnitCount = 0;
        for (LCResourceReplacement *replacement in plan.replacements) {
            @autoreleasepool {
                if (LCCancelled(progress, &failure)) break;
                if (![self validateContainer:replacement.source.containerURL error:&failure] ||
                    ![self validateContainer:replacement.target.containerURL error:&failure]) break;
                NSDictionary *record;
                if (!LCReplace(replacement, progress, &failure, &record)) break;
                result.compactedFileCount++;
                result.sharedBytes += replacement.target.identity.st_size;
                NSString *key = replacement.target.containerURL.path;
                if (record) {
                    if (!manifests[key]) manifests[key] = [[self manifestForContainer:replacement.target.containerURL] mutableCopy];
                    manifests[key][replacement.target.name] = record;
                }
            }
        }
        for (NSString *path in manifests) {
            NSURL *url = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:LCManifestName];
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version": @1, @"files": manifests[path]}
                                                                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            // The marker is advisory, never trusted for content verification.
            // A failed write cannot invalidate an already verified clone.
            [data writeToURL:url options:NSDataWritingAtomic error:nil];
        }
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
