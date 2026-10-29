#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Opt-in playback compatibility for injected virtual LiveProcess windows.
BOOL LCAmbientAudioShouldEnable(BOOL liveProcess, NSString * _Nullable guestAppId,
                               NSDictionary *appInfo, NSDictionary * _Nullable launchInfo);
void LCAmbientAudioInstall(void);

NS_ASSUME_NONNULL_END
