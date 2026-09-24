//
//  ClipboardSettingsViewController.h
//  iSH
//
//  Settings for the clipboard manager, plus a list of its keyboard shortcuts.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClipboardSettingsViewController : UITableViewController
// Wrapped in a navigation controller with a Done button, ready to present.
+ (UIViewController *)navigationControllerWithDismissHandler:(nullable void (^)(void))dismissHandler;
@end

NS_ASSUME_NONNULL_END
