//
//  TabBarView.h
//  iSH
//
//  A strip of shell tabs shown above the terminal, in the style of Hyper's tab bar:
//  tabs share the width, the selected tab is the terminal color with no seam, and the
//  close control only appears on the selected or hovered tab.
//

#import <UIKit/UIKit.h>
#import "TerminalSession.h"

NS_ASSUME_NONNULL_BEGIN

@class TabBarView;

@protocol TabBarViewDelegate <NSObject>
- (void)tabBar:(TabBarView *)tabBar didSelectTabAtIndex:(NSUInteger)index;
- (void)tabBar:(TabBarView *)tabBar didRequestCloseTabAtIndex:(NSUInteger)index;
- (void)tabBar:(TabBarView *)tabBar didRequestCloseOtherTabsAtIndex:(NSUInteger)index;
- (void)tabBar:(TabBarView *)tabBar didRequestRenameTabAtIndex:(NSUInteger)index;
- (void)tabBarDidRequestNewTab:(TabBarView *)tabBar;
// The menu behind the strip's ⋯ button; asked for each time it opens.
- (nullable UIMenu *)commandsMenuForTabBar:(TabBarView *)tabBar;
@end

@interface TabBarView : UIView

@property (weak, nullable) id <TabBarViewDelegate> delegate;

// Updates the strip in place. Cheap enough to call on every change; tab counts are small.
- (void)setSessions:(NSArray<TerminalSession *> *)sessions selectedIndex:(NSUInteger)selectedIndex;

// Colors follow the terminal theme: background is the terminal background.
- (void)setBackgroundColor:(UIColor *)background foregroundColor:(UIColor *)foreground;

@end

NS_ASSUME_NONNULL_END
