#import "../LCAppLocationSettings.h"

// Call only while bootstrapping an opted-in guest, before guest initializers.
void LCCustomLocationInstall(NSDictionary *settings);
void LCCustomLocationUpdate(NSDictionary *snapshot);
