//
//  TabBarView.h
//  iSH
//
//  A strip of shell tabs shown above the terminal.
//

#import <UIKit/UIKit.h>
#import "TerminalSession.h"

NS_ASSUME_NONNULL_BEGIN

@class TabBarView;

@protocol TabBarViewDelegate <NSObject>
- (void)tabBar:(TabBarView *)tabBar didSelectTabAtIndex:(NSUInteger)index;
- (void)tabBar:(TabBarView *)tabBar didRequestCloseTabAtIndex:(NSUInteger)index;
- (void)tabBar:(TabBarView *)tabBar didRequestRenameTabAtIndex:(NSUInteger)index;
- (void)tabBarDidRequestNewTab:(TabBarView *)tabBar;
@end

@interface TabBarView : UIView

@property (weak, nullable) id <TabBarViewDelegate> delegate;

// Rebuilds the strip. Cheap enough to call on every change; tab counts are small.
- (void)setSessions:(NSArray<TerminalSession *> *)sessions selectedIndex:(NSUInteger)selectedIndex;

// Colors follow the terminal theme.
- (void)setBackgroundColor:(UIColor *)background foregroundColor:(UIColor *)foreground;

@end

NS_ASSUME_NONNULL_END
