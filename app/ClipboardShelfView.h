//
//  ClipboardShelfView.h
//  iSH
//
//  The clipboard manager's main surface: a Liquid Glass shelf at the bottom of the
//  window, in the style of Paste for Mac. A strip of tabs (the history and each
//  pinboard) sits over a row of item cards; search replaces the tabs with a field
//  that takes filter tokens. While shown it is the first responder and handles
//  Paste's keyboard shortcuts.
//

#import <UIKit/UIKit.h>
#import "ClipboardStore.h"

NS_ASSUME_NONNULL_BEGIN

@class ClipboardShelfView;

@protocol ClipboardShelfDelegate <NSObject>
// Types text into the terminal the shelf was opened over.
- (void)shelf:(ClipboardShelfView *)shelf pasteText:(NSString *)text;
- (void)shelfDidRequestClose:(ClipboardShelfView *)shelf;
- (UIViewController *)presentingViewControllerForShelf:(ClipboardShelfView *)shelf;
- (void)shelfDidRequestSettings:(ClipboardShelfView *)shelf;
- (void)shelfDidRequestPasteStack:(ClipboardShelfView *)shelf;
@end

@interface ClipboardShelfView : UIView

@property (weak, nullable) id<ClipboardShelfDelegate> delegate;

// The height the shelf wants for the current card size.
@property (readonly) CGFloat preferredHeight;

// Called just before the shelf appears: refreshes and selects the first item.
- (void)prepareToShow;
- (void)beginSearch;
- (void)promptForNewPinboard;

@end

NS_ASSUME_NONNULL_END
