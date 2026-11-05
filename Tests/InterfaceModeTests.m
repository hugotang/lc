#import <XCTest/XCTest.h>
// Exercise explicit installation without a bootstrap constructor in the test host.
#import "../LiveContainer/Tweaks/InterfaceMode.m"

@interface InterfaceModeTests : XCTestCase
@end

@implementation InterfaceModeTests
- (void)testOnlyOptedInVirtualGuestsUseTheSelectedInterfaceMode {
    NSDictionary *virtual = @{@"virtualWindow": @YES};
    for (NSNumber *mode in @[@1, @2]) {
        NSDictionary *info = @{LCAppInterfaceModeKey: mode};
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", info, virtual), mode.integerValue);
        XCTAssertEqual(LCInterfaceModeForLaunch(NO, @"game", info, virtual), LCAppInterfaceModeAutomatic);
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, nil, info, virtual), LCAppInterfaceModeAutomatic);
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", info, nil), LCAppInterfaceModeAutomatic);
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", info, @{@"virtualWindow": @NO}), LCAppInterfaceModeAutomatic);
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", info, @{@"virtualWindow": @"YES"}), LCAppInterfaceModeAutomatic);
        XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game",
            @{LCAppInterfaceModeKey: mode, @"dontInjectTweakLoader": @YES}, virtual), LCAppInterfaceModeAutomatic);
    }
    XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", @{}, virtual), LCAppInterfaceModeAutomatic);
    NSDictionary *snapshot = @{@"virtualWindow": @YES, @"appDisplaySettings": @{LCAppInterfaceModeKey: @1}};
    XCTAssertEqual(LCInterfaceModeForLaunch(YES, @"game", @{LCAppInterfaceModeKey: @2}, snapshot), LCAppInterfaceModePhone);
}
- (void)testDeviceAndCachedTraitsAgreeWithoutChangingSizeClassesOrScale {
    Method device = class_getInstanceMethod(UIDevice.class, @selector(userInterfaceIdiom));
    Method traits = class_getInstanceMethod(UITraitCollection.class, @selector(userInterfaceIdiom));
    IMP oldDevice = method_getImplementation(device), oldTraits = method_getImplementation(traits);
    UITraitCollection *cached = [UITraitCollection traitCollectionWithTraitsFromCollections:@[
        [UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPad],
        [UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassCompact],
        [UITraitCollection traitCollectionWithDisplayScale:2]
    ]];
    @try {
        LCInterfaceModeInstall(LCAppInterfaceModeAutomatic);
        XCTAssertEqual(method_getImplementation(device), oldDevice);
        LCInterfaceModeInstall(LCAppInterfaceModePhone);
        // Installation is once per guest process. Exercise each possible
        // process's selected value while retaining the production getter hooks.
        for (NSNumber *idiom in @[@(UIUserInterfaceIdiomPhone), @(UIUserInterfaceIdiomPad)]) {
            LCInterfaceIdiom = idiom.integerValue;
            XCTAssertEqual(UIDevice.currentDevice.userInterfaceIdiom, idiom.integerValue);
            XCTAssertEqual(cached.userInterfaceIdiom, idiom.integerValue);
            XCTAssertEqual([UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPhone].userInterfaceIdiom,
                           idiom.integerValue);
            XCTAssertEqual(cached.horizontalSizeClass, UIUserInterfaceSizeClassCompact);
            XCTAssertEqual(cached.displayScale, 2);
        }
    } @finally {
        method_setImplementation(device, oldDevice);
        method_setImplementation(traits, oldTraits);
        LCInterfaceIdiom = UIUserInterfaceIdiomUnspecified;
    }
}
@end
