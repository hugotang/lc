#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(int64_t, LCLivePlugInCommand) {
    LCLivePlugInCommandLaunchConfiguration = 1,
    LCLivePlugInCommandError = 2,
    LCLivePlugInCommandConnect = 3,
};

static const NSTimeInterval LCLivePlugInLaunchTimeout = 30;
static const char *const LCLivePlugInEnvironmentKey = "LC_LIVEPLUGIN";

static inline NSString *LCLivePlugInServiceName(NSString *appGroup, pid_t hostPID) {
    return [NSString stringWithFormat:@"%@.LiveContainer.LivePlugIn-%d", appGroup, hostPID];
}

@interface LCLivePlugIn : NSObject
@property(nonatomic, readonly) pid_t pid;
+ (BOOL)startServerWithError:(NSError **)error;
+ (void)resolvePendingRequests;
- (instancetype)initWithUUID:(NSUUID *)identifier configuration:(NSDictionary *)configuration error:(NSError **)error;
- (BOOL)bindToPID:(pid_t)pid error:(NSError **)error;
- (void)cancelWithError:(NSError *)error;
@end
