#import "InterfaceMode.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIUserInterfaceIdiom LCInterfaceIdiom = UIUserInterfaceIdiomUnspecified;

LCAppInterfaceMode LCInterfaceModeForLaunch(BOOL liveProcess, NSString *guestAppId,
                                           NSDictionary *appInfo, NSDictionary *launchInfo) {
    if (!liveProcess || !guestAppId.length || ![launchInfo[@"virtualWindow"] isEqual:@YES] ||
        [appInfo[@"dontInjectTweakLoader"] boolValue]) return LCAppInterfaceModeAutomatic;
    return LCAppInterfaceModeFromInfo(LCAppDisplaySettingsForLaunch(appInfo, launchInfo));
}

static UIUserInterfaceIdiom LCInterfaceModeIdiom(id object, SEL selector) {
    return LCInterfaceIdiom;
}

void LCInterfaceModeInstall(LCAppInterfaceMode mode) {
    if (mode != LCAppInterfaceModePhone && mode != LCAppInterfaceModePad) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method device = class_getInstanceMethod(UIDevice.class, @selector(userInterfaceIdiom));
        Method traits = class_getInstanceMethod(UITraitCollection.class, @selector(userInterfaceIdiom));
        if (!device || !traits) return;
        LCInterfaceIdiom = mode == LCAppInterfaceModePhone ? UIUserInterfaceIdiomPhone : UIUserInterfaceIdiomPad;
        // The extension has its own process. Existing cached trait collections
        // and newly created ones must agree with UIDevice when the game starts.
        // Size classes, scale, safe areas and hardware identity remain system values.
        method_setImplementation(device, (IMP)LCInterfaceModeIdiom);
        method_setImplementation(traits, (IMP)LCInterfaceModeIdiom);
    });
}
