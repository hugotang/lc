#import "../LCAppLocationSettings.h"

// Install for eligible guests before their initializers; the snapshot controls
// whether their managers use simulation or ordinary system location.
void LCCustomLocationInstall(NSDictionary *settings);
void LCCustomLocationUpdate(NSDictionary *snapshot);
