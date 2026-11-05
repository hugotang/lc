#import "../LCAppDisplaySettings.h"

NS_ASSUME_NONNULL_BEGIN

LCAppInterfaceMode LCInterfaceModeForLaunch(BOOL liveProcess, NSString * _Nullable guestAppId,
                                           NSDictionary *appInfo, NSDictionary * _Nullable launchInfo);
// Only call in an opted-in virtual guest, before loading the guest executable.
void LCInterfaceModeInstall(LCAppInterfaceMode mode);

NS_ASSUME_NONNULL_END
