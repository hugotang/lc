#import "../LiveContainer/LCResourceCompactor.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

static NSProgress *Progress(void) { return [NSProgress progressWithTotalUnitCount:0]; }

@interface LCProgressCancellation : NSObject
@property(nonatomic) NSProgress *progress;
@property(nonatomic) int64_t afterBytes;
- (instancetype)initWithProgress:(NSProgress *)progress afterBytes:(int64_t)afterBytes;
@end
@implementation LCProgressCancellation
- (instancetype)initWithProgress:(NSProgress *)progress afterBytes:(int64_t)afterBytes {
    if ((self = [super init])) {
        _progress = progress;
        _afterBytes = afterBytes;
        [progress addObserver:self forKeyPath:@"completedUnitCount" options:0 context:NULL];
    }
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)keyPath; (void)object; (void)change; (void)context;
    if (self.progress.completedUnitCount > self.afterBytes) [self.progress cancel];
}
- (void)dealloc { [_progress removeObserver:self forKeyPath:@"completedUnitCount"]; }
@end

static NSURL *Resource(NSURL *container, NSString *name) {
    return [[container URLByAppendingPathComponent:LCResourceCompactor.resourceRelativePath] URLByAppendingPathComponent:name];
}

static NSData *Asset(BOOL audio, NSUInteger seed) {
    NSMutableData *data = [NSMutableData dataWithLength:512 * 1024];
    unsigned char *bytes = data.mutableBytes;
    memcpy(bytes, audio ? "OggS" : "PK\x03\x04", 4);
    uint32_t state = (uint32_t)(seed + 1);
    for (NSUInteger i = 4; i < data.length; i++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        bytes[i] = state & 0xff;
    }
    return data;
}

static NSURL *MakeContainer(NSURL *root, NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *container = [root URLByAppendingPathComponent:name];
    assert([fm createDirectoryAtURL:[container URLByAppendingPathComponent:LCResourceCompactor.resourceRelativePath]
       withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtURL:[container URLByAppendingPathComponent:@"Documents"]
       withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(([@{@"appIdentifier": LCResourceCompactor.supportedBundleIdentifier, @"keychainGroupId": @12}
            writeToURL:[container URLByAppendingPathComponent:@"LCContainerInfo.plist"] atomically:YES]));
    return container;
}

static void Write(NSURL *url, NSData *data) {
    assert([data writeToURL:url options:NSDataWritingAtomic error:nil]);
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY);
    assert(descriptor >= 0 && !fsync(descriptor)); close(descriptor);
}

static LCResourceCompactionPlan *Scan(NSArray<NSURL *> *containers) {
    NSError *error = nil;
    LCResourceCompactionPlan *plan = [LCResourceCompactor scanContainers:containers
                       bundleIdentifier:LCResourceCompactor.supportedBundleIdentifier progress:Progress() error:&error];
    if (!plan) NSLog(@"Unexpected scan failure: %@", error);
    assert(plan && !error);
    return plan;
}

static LCResourceCompactionResult *Apply(LCResourceCompactionPlan *plan) {
    NSError *error = nil;
    LCResourceCompactionResult *result = [LCResourceCompactor applyPlan:plan progress:Progress() error:&error];
    if (!result) NSLog(@"Unexpected apply failure: %@", error);
    assert(result && !error && !result.stoppedError);
    return result;
}

static void CheckNoTemporaryClones(NSURL *container) {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:
        [container URLByAppendingPathComponent:LCResourceCompactor.resourceRelativePath]
        includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *item in items) assert(![item.lastPathComponent hasPrefix:@".lc-resource-clone-"]);
}

// Read physical maps independently of the compactor so a full data copy with
// the correct hashes and separate inodes cannot pass as storage sharing.
static void CheckSharedExtents(NSURL *sourceURL, NSURL *targetURL) {
    int sourceFD = open(sourceURL.fileSystemRepresentation, O_RDONLY);
    int targetFD = open(targetURL.fileSystemRepresentation, O_RDONLY);
    struct stat sourceStat, targetStat;
    assert(sourceFD >= 0 && targetFD >= 0 && !fstat(sourceFD, &sourceStat) && !fstat(targetFD, &targetStat));
    assert(sourceStat.st_dev == targetStat.st_dev && sourceStat.st_size == targetStat.st_size);
    for (off_t offset = 0; offset < sourceStat.st_size;) {
        struct log2phys source = { .l2p_contigbytes = sourceStat.st_size - offset, .l2p_devoffset = offset };
        struct log2phys target = { .l2p_contigbytes = targetStat.st_size - offset, .l2p_devoffset = offset };
        assert(!fcntl(sourceFD, F_LOG2PHYS_EXT, &source) && !fcntl(targetFD, F_LOG2PHYS_EXT, &target));
        assert(source.l2p_devoffset >= 0 && source.l2p_devoffset == target.l2p_devoffset);
        assert(source.l2p_contigbytes > 0 && target.l2p_contigbytes > 0);
        offset += MIN(sourceStat.st_size - offset, MIN(source.l2p_contigbytes, target.l2p_contigbytes));
    }
    close(sourceFD); close(targetFD);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:
            [@"LCResourceCompactionTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        @try {
            NSURL *a = MakeContainer(root, @"account-a"), *b = MakeContainer(root, @"account-b");
            NSData *first = Asset(NO, 1), *second = Asset(YES, 2);
            Write(Resource(a, @"data02.bin"), first); Write(Resource(b, @"data02.bin"), first);
            Write(Resource(a, @"data03.bin"), second); Write(Resource(b, @"data03.bin"), second);
            // Equal-sized but different files must never be coalesced.
            Write(Resource(a, @"data04.bin"), Asset(NO, 3)); Write(Resource(b, @"data04.bin"), Asset(NO, 4));
            // Known differing/private files remain excluded even if they happen to match.
            Write(Resource(a, @"data12.bin"), first); Write(Resource(b, @"data12.bin"), first);
            Write(Resource(a, @"data17.bin"), first); Write(Resource(b, @"data17.bin"), first);
            Write(Resource(a, @"data05.bin"), [@"unknown binary" dataUsingEncoding:NSUTF8StringEncoding]);
            Write(Resource(b, @"data05.bin"), [@"unknown binary" dataUsingEncoding:NSUTF8StringEncoding]);
            Write(Resource(a, @"private.bin"), first); Write(Resource(b, @"private.bin"), first);
            NSURL *nestedA = Resource(a, @"nested"), *nestedB = Resource(b, @"nested");
            assert([fm createDirectoryAtURL:nestedA withIntermediateDirectories:NO attributes:nil error:nil]);
            assert([fm createDirectoryAtURL:nestedB withIntermediateDirectories:NO attributes:nil error:nil]);
            Write([nestedA URLByAppendingPathComponent:@"data06.bin"], first);
            Write([nestedB URLByAppendingPathComponent:@"data06.bin"], first);
            assert([fm createSymbolicLinkAtURL:Resource(b, @"data07.bin") withDestinationURL:Resource(a, @"data02.bin") error:nil]);
            NSURL *outside = [root URLByAppendingPathComponent:@"outside.bin"];
            Write(outside, first);
            assert(link(outside.fileSystemRepresentation, Resource(b, @"data08.bin").fileSystemRepresentation) == 0);
            Write(Resource(a, @"data08.bin"), first);
            NSURL *saveA = [a URLByAppendingPathComponent:@"Documents/data11.bin"];
            NSURL *saveB = [b URLByAppendingPathComponent:@"Documents/data11.bin"];
            Write(saveA, [@"account-a-save" dataUsingEncoding:NSUTF8StringEncoding]);
            Write(saveB, [@"account-b-save" dataUsingEncoding:NSUTF8StringEncoding]);
            NSData *beforeA = [NSData dataWithContentsOfURL:saveA], *beforeB = [NSData dataWithContentsOfURL:saveB];
            NSData *privateBefore = [NSData dataWithContentsOfURL:Resource(b, @"data12.bin")];
            struct stat privateIdentity, destinationBefore;
            assert(!lstat(Resource(b, @"data12.bin").fileSystemRepresentation, &privateIdentity));
            assert(!chmod(Resource(b, @"data02.bin").fileSystemRepresentation, 0640));
            const char *attributeName = "com.livecontainer.compaction-test";
            const char *attributeValue = "target-metadata";
            assert(!setxattr(Resource(b, @"data02.bin").fileSystemRepresentation, attributeName,
                             attributeValue, strlen(attributeValue), 0, 0));
            assert(!lstat(Resource(b, @"data02.bin").fileSystemRepresentation, &destinationBefore));

            NSError *error = nil;
            int shared = [LCResourceCompactor acquireSharedLeaseForContainerAtURL:b error:&error];
            assert(shared >= 0 && !error);
            assert((![LCResourceCompactor scanContainers:@[a,b] bundleIdentifier:LCResourceCompactor.supportedBundleIdentifier
                                                  progress:Progress() error:&error]));
            assert(error.code == LCResourceCompactionErrorBusy);
            close(shared);

            LCResourceCompactionPlan *plan = Scan(@[b,a]);
            assert(plan.containerCount == 2 && plan.matchingFileCount == 2);
            assert(plan.candidateBytes == (int64_t)(first.length + second.length));
            assert(plan.independentFileCount >= 10);
            assert(plan.verifiedSharedFileCount == 0 && plan.verifiedSharedBytes == 0);
            assert(plan.sharingUnavailableFileCount == 0);
            assert([LCResourceCompactor availableBytesForContainers:@[]] == nil);
            assert([LCResourceCompactor availableBytesForContainers:@[[root URLByAppendingPathComponent:@"missing"]]] == nil);
            struct statfs filesystem;
            assert(!statfs(a.fileSystemRepresentation, &filesystem));
            int64_t expectedAvailable = (int64_t)filesystem.f_bavail * filesystem.f_bsize;
            NSNumber *measuredAvailable = [LCResourceCompactor availableBytesForContainers:@[a,b,a]];
            assert(measuredAvailable && llabs(measuredAvailable.longLongValue - expectedAvailable) < 4 * 1024 * 1024);
            error = nil;
            NSProgress *cancelled = Progress(); [cancelled cancel];
            assert(![LCResourceCompactor applyPlan:plan progress:cancelled error:&error]);
            assert(error.code == LCResourceCompactionErrorCancelled);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data02.bin")] isEqual:first]);

            // A stale plan must fail before overwriting a changed resource.
            NSMutableData *changed = [first mutableCopy]; ((unsigned char *)changed.mutableBytes)[10] ^= 0x7f;
            Write(Resource(b, @"data02.bin"), changed);
            error = nil;
            assert(![LCResourceCompactor applyPlan:plan progress:Progress() error:&error]);
            assert(error.code == LCResourceCompactionErrorChanged);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data02.bin")] isEqual:changed]);
            Write(Resource(b, @"data02.bin"), first);
            assert(!chmod(Resource(b, @"data02.bin").fileSystemRepresentation, 0640));
            assert(!lstat(Resource(b, @"data02.bin").fileSystemRepresentation, &destinationBefore));

            LCResourceCompactionResult *result = Apply(Scan(@[a,b]));
            assert(result.compactedFileCount == 2 && result.processedBytes == (int64_t)(first.length + second.length));
            assert(result.verifiedSharedFileCount == 2 && result.sharingUnavailableFileCount == 0);
            assert(result.availableBytesBefore && result.availableBytesAfter && result.completedAt);
            CheckSharedExtents(Resource(a, @"data02.bin"), Resource(b, @"data02.bin"));
            CheckSharedExtents(Resource(a, @"data03.bin"), Resource(b, @"data03.bin"));
            LCResourceCompactionResult *savedResult = [LCResourceCompactor lastResultForContainers:@[b,a]];
            assert(savedResult && savedResult.compactedFileCount == result.compactedFileCount &&
                   savedResult.processedBytes == result.processedBytes);
            assert([savedResult.availableBytesBefore isEqual:result.availableBytesBefore] &&
                   [savedResult.availableBytesAfter isEqual:result.availableBytesAfter]);
            assert([savedResult.completedAt isEqual:result.completedAt] && !savedResult.stoppedError);
            assert([LCResourceCompactor lastResultForContainers:@[a]] == nil);
            struct stat sourceAfter, targetAfter, privateAfter;
            assert(!lstat(Resource(a, @"data02.bin").fileSystemRepresentation, &sourceAfter));
            assert(!lstat(Resource(b, @"data02.bin").fileSystemRepresentation, &targetAfter));
            assert(sourceAfter.st_ino != targetAfter.st_ino && sourceAfter.st_nlink == 1 && targetAfter.st_nlink == 1);
            assert(targetAfter.st_mode == destinationBefore.st_mode);
            assert(targetAfter.st_mtimespec.tv_sec == destinationBefore.st_mtimespec.tv_sec &&
                   targetAfter.st_mtimespec.tv_nsec == destinationBefore.st_mtimespec.tv_nsec);
            // The stale-plan test rewrote data02, so test xattrs on a separate clone below.
            assert(!lstat(Resource(b, @"data12.bin").fileSystemRepresentation, &privateAfter));
            assert(privateAfter.st_ino == privateIdentity.st_ino);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data12.bin")] isEqual:privateBefore]);
            assert([[NSData dataWithContentsOfURL:saveA] isEqual:beforeA]);
            assert([[NSData dataWithContentsOfURL:saveB] isEqual:beforeB]);
            CheckNoTemporaryClones(a); CheckNoTemporaryClones(b);
            plan = Scan(@[a,b]);
            assert(plan.matchingFileCount == 0 && plan.alreadyCompactedFileCount == 2);
            assert(plan.verifiedSharedFileCount == 2 && plan.verifiedSharedBytes == (int64_t)(first.length + second.length));

            // Copy-on-write may unshare data even when the final bytes are the
            // same again. Re-analysis must detect that despite a recorded clone.
            int sameWriter = open(Resource(b, @"data02.bin").fileSystemRepresentation, O_WRONLY);
            const unsigned char *originalBytes = first.bytes;
            unsigned char temporaryByte = originalBytes[10] ^ 0xff;
            assert(sameWriter >= 0 && pwrite(sameWriter, &temporaryByte, 1, 10) == 1 && !fsync(sameWriter));
            assert(pwrite(sameWriter, originalBytes + 10, 1, 10) == 1 && !fsync(sameWriter)); close(sameWriter);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data02.bin")] isEqual:first]);
            plan = Scan(@[a,b]);
            assert(plan.matchingFileCount == 1 && plan.verifiedSharedFileCount == 1);
            assert(Apply(plan).compactedFileCount == 1);
            CheckSharedExtents(Resource(a, @"data02.bin"), Resource(b, @"data02.bin"));

            // Missing/old advisory manifests do not force replacements when
            // the physical maps already show full sharing.
            NSURL *manifestURL = [b URLByAppendingPathComponent:@".lc-resource-compaction.plist"];
            NSMutableDictionary *oldManifest = [[NSDictionary dictionaryWithContentsOfURL:manifestURL] mutableCopy];
            oldManifest[@"version"] = @1;
            assert([oldManifest writeToURL:manifestURL atomically:YES]);
            assert(Scan(@[a,b]).verifiedSharedFileCount == 2);

            // In-place guest updates separate APFS blocks and cannot modify the peer.
            int writer = open(Resource(b, @"data02.bin").fileSystemRepresentation, O_WRONLY);
            unsigned char byte = 0xa5;
            assert(writer >= 0 && pwrite(writer, &byte, 1, 10) == 1); close(writer);
            assert([[NSData dataWithContentsOfURL:Resource(a, @"data02.bin")] isEqual:first]);
            assert(![[NSData dataWithContentsOfURL:Resource(b, @"data02.bin")] isEqual:first]);
            plan = Scan(@[a,b]);
            assert(plan.matchingFileCount == 0 && plan.alreadyCompactedFileCount == 1);
            Write(Resource(b, @"data02.bin"), first);
            assert(Apply(Scan(@[a,b])).compactedFileCount == 1);
            assert([fm removeItemAtURL:Resource(a, @"data03.bin") error:nil]);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data03.bin")] isEqual:second]);

            // A third account joins through clones, then deletion remains independent.
            NSURL *c = MakeContainer(root, @"account-c");
            Write(Resource(c, @"data02.bin"), first);
            assert(Apply(Scan(@[a,b,c])).compactedFileCount == 1);
            assert([fm removeItemAtURL:c error:nil]);
            assert([[NSData dataWithContentsOfURL:Resource(a, @"data02.bin")] isEqual:first]);
            assert([[NSData dataWithContentsOfURL:Resource(b, @"data02.bin")] isEqual:first]);

            NSURL *d = MakeContainer(root, @"account-d"), *e = MakeContainer(root, @"account-e");
            Write(Resource(d, @"data02.bin"), first); Write(Resource(e, @"data02.bin"), first);
            Write(Resource(d, @"data03.bin"), second); Write(Resource(e, @"data03.bin"), second);
            assert(!setxattr(Resource(e, @"data02.bin").fileSystemRepresentation, attributeName,
                             attributeValue, strlen(attributeValue), 0, 0));
            // Cancel while hashing the second replacement: the first completed
            // file and the unfinished second file must both remain valid.
            NSProgress *partialProgress = Progress();
            LCProgressCancellation *observation = [[LCProgressCancellation alloc]
                initWithProgress:partialProgress afterBytes:(int64_t)first.length * 2];
            error = nil;
            LCResourceCompactionResult *partial = [LCResourceCompactor applyPlan:Scan(@[d,e]) progress:partialProgress error:&error];
            assert(partial && !error && partial.compactedFileCount == 1);
            assert(observation.progress.cancelled && partial.stoppedError.code == LCResourceCompactionErrorCancelled);
            assert([[NSData dataWithContentsOfURL:Resource(e, @"data02.bin")] isEqual:first]);
            assert([[NSData dataWithContentsOfURL:Resource(e, @"data03.bin")] isEqual:second]);
            char restoredAttribute[64] = {0};
            ssize_t attributeLength = getxattr(Resource(e, @"data02.bin").fileSystemRepresentation,
                                               attributeName, restoredAttribute, sizeof(restoredAttribute), 0, 0);
            assert(attributeLength == (ssize_t)strlen(attributeValue) && !memcmp(restoredAttribute, attributeValue, strlen(attributeValue)));
            CheckSharedExtents(Resource(d, @"data02.bin"), Resource(e, @"data02.bin"));
            savedResult = [LCResourceCompactor lastResultForContainers:@[d,e]];
            assert(savedResult && savedResult.compactedFileCount == 1 &&
                   savedResult.stoppedError.code == LCResourceCompactionErrorCancelled);
            assert(savedResult.availableBytesBefore && savedResult.availableBytesAfter);
            CheckNoTemporaryClones(e);
            assert(Apply(Scan(@[d,e])).compactedFileCount == 1);

            error = nil;
            assert((![LCResourceCompactor scanContainers:@[a,a] bundleIdentifier:LCResourceCompactor.supportedBundleIdentifier
                                                  progress:Progress() error:&error]));
            assert(error.code == LCResourceCompactionErrorInvalidContainer);
            NSURL *resourceDir = [b URLByAppendingPathComponent:LCResourceCompactor.resourceRelativePath];
            NSURL *moved = [root URLByAppendingPathComponent:@"moved-resources"];
            assert([fm moveItemAtURL:resourceDir toURL:moved error:nil]);
            assert([fm createSymbolicLinkAtURL:resourceDir withDestinationURL:moved error:nil]);
            error = nil;
            assert((![LCResourceCompactor scanContainers:@[a,b] bundleIdentifier:LCResourceCompactor.supportedBundleIdentifier
                                                  progress:Progress() error:&error]));
            assert(error.code == LCResourceCompactionErrorInvalidContainer);
            assert([fm removeItemAtURL:resourceDir error:nil]);
            assert([fm moveItemAtURL:moved toURL:resourceDir error:nil]);

            // Leases work across processes and disappear automatically on exit.
            int lease = open([[a URLByAppendingPathComponent:LCResourceCompactor.leaseFileName] fileSystemRepresentation], O_RDWR);
            assert(lease >= 0 && !flock(lease, LOCK_EX | LOCK_NB));
            assert([LCResourceCompactor isCompactingContainerAtURL:a]);
            pid_t child = fork();
            assert(child >= 0);
            if (child == 0) {
                close(lease);
                NSError *childError = nil;
                int fd = [LCResourceCompactor acquireSharedLeaseForContainerAtURL:a error:&childError];
                if (fd >= 0) close(fd);
                _exit(fd < 0 && childError.code == LCResourceCompactionErrorBusy ? 0 : 1);
            }
            int status = 0; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
            close(lease);
            assert(![LCResourceCompactor isCompactingContainerAtURL:a]);

            printf("Resource compaction tests passed (SHA-256 equality, verified physical extent sharing, free-space measurements, persisted/partial reports, exclusions, APFS write/delete isolation, stale plans, cancellation, metadata, repeat scans, third accounts, symlinks, hard links and cross-process leases).\n");
        } @finally {
            [fm removeItemAtURL:root error:nil];
        }
    }
    return 0;
}
