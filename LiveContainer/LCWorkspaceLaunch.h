#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

// Shared by the host UI, guest URL hooks and the existing Launch App shortcut.
// A restore link names only the local saved workspace; it cannot supply a snapshot.
NS_INLINE BOOL LCIsWorkspaceRestoreURL(NSURL * _Nullable url, NSString * _Nullable scheme) {
    if (!url || scheme.length == 0) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    return [parts.scheme.lowercaseString isEqualToString:scheme.lowercaseString] &&
        [parts.host.lowercaseString isEqualToString:@"workspace-restore"] &&
        (parts.percentEncodedPath.length == 0 || [parts.percentEncodedPath isEqualToString:@"/"]) &&
        !parts.user && !parts.password && !parts.port && !parts.query && !parts.fragment;
}

NS_INLINE NSURL * _Nullable LCWorkspaceRestoreURL(NSString * _Nullable scheme) {
    if (scheme.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://workspace-restore", scheme]];
    return LCIsWorkspaceRestoreURL(url, scheme) ? url : nil;
}

NS_INLINE void LCClearPendingWorkspaceRestore(NSUserDefaults *defaults) {
    [defaults removeObjectForKey:@"LCPendingWorkspaceRestore"];
}

// Persist only after the normal app-switch confirmation has been accepted.
NS_INLINE void LCQueueWorkspaceRestore(NSUserDefaults *defaults, NSString *scheme, NSDate *date) {
    NSURL *url = LCWorkspaceRestoreURL(scheme);
    if (!url) return;
    [defaults setObject:@{@"url": url.absoluteString, @"date": date} forKey:@"LCPendingWorkspaceRestore"];
}

// A switch restarts the host. Consume the request once, even if it is stale or corrupt.
NS_INLINE NSURL * _Nullable LCConsumePendingWorkspaceRestore(NSUserDefaults *defaults,
                                                            NSString * _Nullable scheme,
                                                            NSDate *now) {
    id stored = [defaults objectForKey:@"LCPendingWorkspaceRestore"];
    LCClearPendingWorkspaceRestore(defaults);
    if (![stored isKindOfClass:NSDictionary.class]) return nil;
    id date = stored[@"date"];
    id value = stored[@"url"];
    if (![date isKindOfClass:NSDate.class] || ![value isKindOfClass:NSString.class]) return nil;
    NSTimeInterval age = [now timeIntervalSinceDate:date];
    if (!isfinite(age) || age < 0 || age > 120) return nil;
    NSURL *url = [NSURL URLWithString:value];
    return LCIsWorkspaceRestoreURL(url, scheme) ? url : nil;
}

NS_ASSUME_NONNULL_END
