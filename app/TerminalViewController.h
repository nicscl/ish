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
// Adopts the sessions that still exist (e.g. after the window was reconnected), in
// order, selecting the given one; starts a new session if none of them exist.
- (void)reconnectSessionsFromTerminalUUIDs:(NSArray<NSUUID *> *)uuids selected:(NSUUID *)selected;
// UUIDs of this window's tabs, in order, and of the selected one (nil if none).
@property (readonly) NSArray<NSUUID *> *tabTerminalUUIDs;
@property (readonly) NSUUID *sessionTerminalUUID;
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

@end

extern struct tty_driver ios_tty_driver;
