#import <UIKit/UIKit.h>

@interface LCTapSyncTestAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UISceneConnectionOptions *connectionOptions;
@end
@implementation LCTapSyncTestAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    self.connectionOptions = options;
    return [[UISceneConfiguration alloc] initWithName:@"Tests" sessionRole:session.role];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTapSyncTestAppDelegate.class)); }
}
