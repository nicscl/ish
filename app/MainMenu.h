//
//  MainMenu.h
//  iSH
//
//  The app's commands, in one place: the main menu (iPadOS menu bar, the hold-⌘
//  shortcut overlay, and the menu bar when running on a Mac) and the same set as
//  a pull-down for touch. Commands are sent up the responder chain to
//  TerminalViewController.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MainMenu : NSObject

+ (void)buildWithBuilder:(id<UIMenuBuilder>)builder;
// The same commands as one menu, for a touch surface such as the tab strip's ⋯ button.
+ (UIMenu *)commandsMenu;

@end

// A user-defined one-liner shown under Tools › Saved Commands. Kept in user defaults.
@interface SavedCommand : NSObject

@property (readonly) NSString *name;
@property (readonly) NSString *command;

+ (NSArray<SavedCommand *> *)all;
+ (void)addWithName:(NSString *)name command:(NSString *)command;
+ (void)removeAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
