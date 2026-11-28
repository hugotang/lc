#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Opt-in other-playback compatibility for injected virtual LiveProcess guests.
BOOL LCBackgroundAudioShouldEnable(BOOL liveProcess, NSString * _Nullable guestAppId,
                                  NSDictionary *appInfo, NSDictionary * _Nullable launchInfo);
void LCBackgroundAudioInstall(NSString *guestExecutablePath);

NS_ASSUME_NONNULL_END
