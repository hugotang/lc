#import "LocationSession.h"
#import "LocationMovement.h"
#import "LocationUI.h"
#import "CustomLocation.h"
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import "../utils.h"

NSNotificationName const LCLocationSessionDidChange = @"LCLocationSessionDidChange";
NSString *LCLocationLocalized(NSString *key) {
    NSBundle *bundle = [NSUserDefaults respondsToSelector:@selector(lcMainBundle)] ? NSUserDefaults.lcMainBundle : NSBundle.mainBundle;
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    if ([value isEqual:key]) {
        NSBundle *english = [NSBundle bundleWithPath:[bundle pathForResource:@"en" ofType:@"lproj"]];
        value = [english localizedStringForKey:key value:key table:nil] ?: key;
    }
    return value;
}

@interface LCLocationSession ()
@property(nonatomic) NSString *bundlePath, *title, *notificationName, *identifier;
@property(nonatomic) NSDictionary *settings, *snapshot;
@property(nonatomic) NSArray<NSDictionary *> *favorites;
@property(nonatomic) NSString *error;
@property(nonatomic) NSString *movementRevision;
@property(nonatomic) NSTimer *movementTimer;
@property(nonatomic) double east, north, speed, lastTick;
@property(nonatomic) int token, movementLock;
@property(nonatomic) BOOL guest;
@end

@implementation LCLocationSession
+ (instancetype)sessionForPath:(NSString *)path title:(NSString *)title {
    NSAssert(NSThread.isMainThread, @"Location sessions use the main thread");
    static NSMutableDictionary *sessions;
    if (!sessions) sessions = [NSMutableDictionary new];
    path = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    LCLocationSession *session = sessions[path];
    if (!session) {
        session = [LCLocationSession new];
        session.bundlePath = path; session.title = title; session.identifier = NSUUID.UUID.UUIDString;
        session.movementLock = -1;
        NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *key = [NSMutableString new];
        for (NSUInteger index = 0; index < sizeof(digest); index++) [key appendFormat:@"%02x", digest[index]];
        session.notificationName = [@"com.livecontainer.location." stringByAppendingString:key];
        session.token = NOTIFY_TOKEN_INVALID;
        __weak LCLocationSession *weakSession = session;
        notify_register_dispatch(session.notificationName.UTF8String, &session->_token, dispatch_get_main_queue(), ^(int token) {
            [weakSession refresh];
        });
        [NSNotificationCenter.defaultCenter addObserver:session selector:@selector(stopMoving) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:session selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
        sessions[path] = session;
        [session refresh];
    }
    return session;
}
- (NSString *)infoPath { return [self.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]; }
- (NSString *)livePath { return [self.bundlePath stringByAppendingPathComponent:@".lc-location-live.plist"]; }
- (BOOL)moving { return self.movementTimer != nil; }
- (void)changed {
    if (self.guest) LCCustomLocationUpdate(self.snapshot);
    [NSNotificationCenter.defaultCenter postNotificationName:LCLocationSessionDidChange object:self];
}
- (void)refresh {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:self.infoPath];
    self.settings = LCAppLocationSettings(info[LCAppLocationKey]);
    _quickControlEnabled = [info[@"LCLocationQuickControl"] boolValue];
    id favorites = info[@"LCLocationFavorites"];
    NSMutableArray *validFavorites = [NSMutableArray new];
    if ([favorites isKindOfClass:NSArray.class]) for (id point in favorites) {
        NSDictionary *valid = LCAppLocationSettings(point);
        if (valid.count && validFavorites.count < 20) [validFavorites addObject:valid];
    }
    self.favorites = validFavorites;
    NSDictionary *live = [NSDictionary dictionaryWithContentsOfFile:self.livePath];
    BOOL sameRevision = [live[@"savedRevision"] isEqual:info[@"LCLocationRevision"] ?: @""];
    if (sameRevision && LCAppLocationSettings(live).count) self.snapshot = live;
    else self.snapshot = self.settings;
    if (self.moving && (!sameRevision || ![live[@"owner"] isEqual:self.identifier])) [self abandonMovement];
    [self changed];
}
- (BOOL)writeInfo:(void (^)(NSMutableDictionary *))modify {
    return [self writeInfoForRevision:nil modify:modify];
}
- (BOOL)writeInfoForRevision:(NSString *)revision modify:(void (^)(NSMutableDictionary *))modify {
    // Reload while holding the lock so two accounts cannot overwrite each
    // other's location preferences. Never write cached full app settings.
    NSString *lockPath = [self.bundlePath stringByAppendingPathComponent:@".lc-location-settings.lock"];
    int descriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (descriptor < 0 || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (descriptor >= 0) close(descriptor);
        self.error = @"lc.location.saveFailed"; [self changed]; return NO;
    }
    NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:self.infoPath] mutableCopy];
    if (revision && ![revision isEqual:info[@"LCLocationRevision"] ?: @""]) {
        flock(descriptor, LOCK_UN); close(descriptor);
        [self abandonMovement]; [self refresh]; return NO;
    }
    BOOL success = NO;
    if (info) { modify(info); success = [info writeToFile:self.infoPath atomically:YES]; }
    flock(descriptor, LOCK_UN); close(descriptor);
    self.error = success ? nil : @"lc.location.saveFailed";
    if (success) { [self refresh]; notify_post(self.notificationName.UTF8String); }
    else [self changed];
    return success;
}
- (BOOL)selectPoint:(NSDictionary *)point enabled:(BOOL)enabled {
    NSDictionary *valid = LCAppLocationSettings(point);
    if (!valid.count) return NO;
    [self abandonMovement];
    return [self writeInfo:^(NSMutableDictionary *info) {
        NSMutableDictionary *value = [valid mutableCopy]; value[@"enabled"] = @(enabled);
        info[LCAppLocationKey] = value; info[@"LCLocationRevision"] = NSUUID.UUID.UUIDString;
    }];
}
- (BOOL)setLocationEnabled:(BOOL)enabled {
    return [self selectPoint:self.snapshot enabled:enabled];
}
- (BOOL)setQuickControlEnabled:(BOOL)enabled {
    return [self writeInfo:^(NSMutableDictionary *info) { info[@"LCLocationQuickControl"] = @(enabled); }];
}
- (void)addFavorite {
    NSDictionary *point = LCAppLocationSettings(self.snapshot);
    if (!point.count) return;
    [self writeInfo:^(NSMutableDictionary *info) {
        NSMutableArray *items = [info[@"LCLocationFavorites"] isKindOfClass:NSArray.class] ? [info[@"LCLocationFavorites"] mutableCopy] : [NSMutableArray new];
        if (![items containsObject:point]) [items insertObject:point atIndex:0];
        if (items.count > 20) [items removeLastObject];
        info[@"LCLocationFavorites"] = items;
    }];
}
- (void)removeFavoriteAtIndex:(NSUInteger)index {
    if (index >= self.favorites.count) return;
    NSDictionary *point = self.favorites[index];
    [self writeInfo:^(NSMutableDictionary *info) {
        NSMutableArray *items = [info[@"LCLocationFavorites"] isKindOfClass:NSArray.class] ? [info[@"LCLocationFavorites"] mutableCopy] : [NSMutableArray new];
        [items removeObject:point];
        info[@"LCLocationFavorites"] = items;
    }];
}
- (BOOL)publish:(NSDictionary *)value {
    NSMutableDictionary *live = [value mutableCopy];
    NSString *lockPath = [self.bundlePath stringByAppendingPathComponent:@".lc-location-settings.lock"];
    int descriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (descriptor < 0 || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (descriptor >= 0) close(descriptor);
        self.error = @"lc.location.saveFailed"; [self abandonMovement]; [self changed]; return NO;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:self.infoPath];
    // Preserve the revision captured when movement started. A new selection
    // from another account supersedes motion even if its notification is late.
    if (!info || ![self.movementRevision isEqual:info[@"LCLocationRevision"] ?: @""]) {
        flock(descriptor, LOCK_UN); close(descriptor);
        [self abandonMovement]; [self refresh]; return NO;
    }
    live[@"savedRevision"] = info[@"LCLocationRevision"] ?: @"";
    live[@"owner"] = self.identifier; live[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
    BOOL success = [live writeToFile:self.livePath atomically:YES];
    flock(descriptor, LOCK_UN); close(descriptor);
    if (!success) {
        self.error = @"lc.location.saveFailed"; [self abandonMovement]; [self changed]; return NO;
    }
    self.snapshot = live; [self changed]; notify_post(self.notificationName.UTF8String); return YES;
}
- (void)moveEast:(double)east north:(double)north speed:(double)speed {
    if (!isfinite(east) || !isfinite(north) || !isfinite(speed) || ![self.snapshot[@"enabled"] boolValue]) return;
    double magnitude = hypot(east, north);
    if (magnitude < 0.12 || speed <= 0) { [self stopMoving]; return; }
    self.east = east / magnitude; self.north = north / magnitude; self.speed = fmin(30, speed);
    if (self.moving) return;
    [self refresh];
    if (![self.snapshot[@"enabled"] boolValue]) return;
    NSString *lockPath = [self.bundlePath stringByAppendingPathComponent:@".lc-location-movement.lock"];
    int descriptor = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (descriptor < 0 || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (descriptor >= 0) close(descriptor);
        self.error = @"lc.location.otherController"; [self changed]; return;
    }
    self.movementLock = descriptor; self.error = nil; self.lastTick = NSProcessInfo.processInfo.systemUptime;
    // Capture the point and revision together, after taking movement ownership.
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:self.infoPath];
    self.movementRevision = info[@"LCLocationRevision"] ?: @"";
    [self refresh];
    if (![self.snapshot[@"enabled"] boolValue]) { [self abandonMovement]; return; }
    NSMutableDictionary *snapshot = [self.snapshot mutableCopy]; snapshot[@"speed"] = @(self.speed);
    snapshot[@"course"] = @(fmod(atan2(self.east, self.north) * 180 / M_PI + 360, 360));
    if (![self publish:snapshot]) return;
    __weak typeof(self) weakSelf = self;
    self.movementTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    self.movementTimer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:self.movementTimer forMode:NSRunLoopCommonModes]; [self changed];
}
- (void)tick {
    double now = NSProcessInfo.processInfo.systemUptime, elapsed = fmin(1.5, fmax(0, now - self.lastTick));
    self.lastTick = now;
    double latitude, longitude, course;
    LCLocationAdvance([self.snapshot[@"latitude"] doubleValue], [self.snapshot[@"longitude"] doubleValue],
                      self.east, self.north, self.speed, elapsed, &latitude, &longitude, &course);
    NSMutableDictionary *value = [self.snapshot mutableCopy];
    value[@"latitude"] = @(latitude); value[@"longitude"] = @(longitude); value[@"name"] = @"";
    value[@"speed"] = @(self.speed); value[@"course"] = @(course);
    [self publish:value];
}
- (void)abandonMovement {
    [self.movementTimer invalidate]; self.movementTimer = nil;
    if (self.movementLock >= 0) { flock(self.movementLock, LOCK_UN); close(self.movementLock); self.movementLock = -1; }
}
- (void)stopMoving {
    if (!self.moving) return;
    NSDictionary *point = self.snapshot;
    // Compare and save under the same settings lock. A newer selection wins,
    // even if another process has not delivered its notification yet.
    [self writeInfoForRevision:self.movementRevision modify:^(NSMutableDictionary *info) {
        info[LCAppLocationKey] = LCAppLocationSettings(point);
        info[@"LCLocationRevision"] = NSUUID.UUID.UUIDString;
    }];
    [self abandonMovement];
    [self changed];
}
@end

void LCLocationStartGuest(NSString *bundlePath, NSString *title, BOOL guestControls) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    LCCustomLocationInstall(info[LCAppLocationKey]);
    dispatch_async(dispatch_get_main_queue(), ^{
        LCLocationSession *session = [LCLocationSession sessionForPath:bundlePath title:title];
        session.guest = YES; [session refresh];
        if (guestControls) [LCLocationUI installGuestControlsForSession:session];
    });
}
