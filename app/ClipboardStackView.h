//
//  ClipboardStackView.h
//  iSH
//
//  The Paste Stack: a small glass panel that collects everything copied while it
//  is open. Paste (⌘V) then takes items off it in order.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClipboardStackView : UIView
@property (copy, nullable) void (^closeHandler)(void);
@end

NS_ASSUME_NONNULL_END
