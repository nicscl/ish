//
//  ClipboardItemViewController.h
//  iSH
//
//  A sheet for one clipboard item: a Quick Look style preview (with ← and → going
//  through the list it came from), an editor, or a blank editor for a new text item.
//

#import <UIKit/UIKit.h>
#import "ClipboardStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface ClipboardItemViewController : UINavigationController

- (instancetype)initWithItems:(NSArray<ClipItem *> *)items index:(NSUInteger)index;
- (instancetype)initForEditingItem:(ClipItem *)item;
- (instancetype)initForNewItemInPinboard:(nullable ClipPinboard *)pinboard;

// Paste from the preview; the sheet is dismissed first.
@property (copy, nullable) void (^pasteHandler)(NSArray<ClipItem *> *items, BOOL plainText);
// Runs after the sheet goes away, however it was closed.
@property (copy, nullable) void (^dismissHandler)(void);

@end

NS_ASSUME_NONNULL_END
