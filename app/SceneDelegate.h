//
//  SceneDelegate.h
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import <UIKit/UIKit.h>
#import "TerminalViewController.h"

NS_ASSUME_NONNULL_BEGIN

extern TerminalViewController *currentTerminalViewController;

// Restoration activity type and keys: the selected tab, and the ordered list of all tabs.
extern NSString *const SceneActivityType;
extern NSString *const SceneTerminalUUIDKey;
extern NSString *const SceneTerminalUUIDsKey;

// All session UUIDs recorded in a scene's restoration activity (selected first).
extern NSArray<NSUUID *> *SceneTerminalUUIDs(NSUserActivity *activity);

// The terminal controllers of every window currently on screen (connected scene).
extern NSArray<TerminalViewController *> *ConnectedTerminalViewControllers(void);

API_AVAILABLE(ios(13))
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic) UIWindow *window;

@end

NS_ASSUME_NONNULL_END
