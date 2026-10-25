#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Launch metadata distinguishes virtual windows from native LiveProcess scenes.
BOOL LCWindowScreenShouldEnable(BOOL isLiveProcess, NSString * _Nullable guestAppId,
                               NSDictionary *appInfo, NSDictionary * _Nullable launchInfo);
void LCWindowScreenInstall(NSDictionary *launchInfo);

NS_ASSUME_NONNULL_END
