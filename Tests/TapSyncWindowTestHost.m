#import <UIKit/UIKit.h>

// Keep one ordinary scene/window alive through the whole XCTest run. Replacing
// a scene's only key window in every case leaves UIKit appearance work in flight.
@interface LCTapSyncTestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation LCTapSyncTestSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.accessibilityIdentifier = @"LCTapSyncTestHostWindow";
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.clearColor;
    [self.window makeKeyAndVisible];
}
@end

@interface LCTapSyncTestAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation LCTapSyncTestAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Tests" sessionRole:session.role];
    configuration.delegateClass = LCTapSyncTestSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTapSyncTestAppDelegate.class)); }
}
