#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Launch metadata distinguishes virtual windows from native LiveProcess scenes.
BOOL LCWindowScreenShouldEnable(BOOL isLiveProcess, NSString * _Nullable guestAppId,
                               NSDictionary *appInfo, NSDictionary * _Nullable launchInfo);
void LCWindowScreenInstall(NSDictionary *launchInfo);
// Read-only, on-demand diagnostics use the same bound game as the ad hooks.
UIWindow * _Nullable LCWindowScreenGameWindowForDiagnostics(void);
NSDictionary *LCWindowScreenGeometryForDiagnostics(void);

NS_ASSUME_NONNULL_END
