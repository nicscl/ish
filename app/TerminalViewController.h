//
//  ViewController.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

@interface TerminalViewController : UIViewController

@property (nonatomic) Terminal *terminal;

// Opens a new shell in a new tab and selects it.
- (void)startNewSession;
// Adopts an existing session (e.g. after the window was reconnected); starts a new one if it no longer exists.
- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid;
// UUID of the selected tab's session, nil if none.
@property (readonly) NSUUID *sessionTerminalUUID;
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

@end

extern struct tty_driver ios_tty_driver;
