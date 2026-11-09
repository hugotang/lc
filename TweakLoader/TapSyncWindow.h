#import <UIKit/UIKit.h>
#import "../MultitaskSupport/TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Call on the main queue; select content before checking auxiliary windows in its scene.
UIWindow * _Nullable LCTapSyncFindGuestWindow(NSSet<UIScene *> *scenes, LCTapSyncResult * _Nullable result);
// Text mode permits UIKit's keyboard windows, while retaining ordinary overlay/alert checks.
UIWindow * _Nullable LCTapSyncFindTextGuestWindow(NSSet<UIScene *> *scenes, LCTapSyncResult * _Nullable result);
BOOL LCTapSyncIsSystemKeyboardWindow(UIWindow *window);
BOOL LCTapSyncWindowIsCovered(UIWindow *guest, NSArray<UIWindow *> *windows);

NS_ASSUME_NONNULL_END
