//
//  TerminalView.h
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

enum OverrideAppearance {
    OverrideAppearanceNone,
    OverrideAppearanceLight,
    OverrideAppearanceDark,
};

@interface TerminalView : UIView <UITextInput, WKScriptMessageHandler, UIScrollViewDelegate>

@property IBInspectable (nonatomic) BOOL canBecomeFirstResponder;

@property (nonatomic) CGFloat overrideFontSize;
@property (readonly) CGFloat effectiveFontSize;
@property (nonatomic) enum OverrideAppearance overrideAppearance;

@property (nonatomic) UIKeyboardAppearance keyboardAppearance;

@property (weak) IBOutlet UIInputView *inputAccessoryView;
@property (weak) IBOutlet UIButton *controlKey;

@property (nonatomic) Terminal *terminal;

// Consulted by paste: before it pastes the system clipboard; returns YES if it
// pasted something itself (the clipboard manager's Paste Stack).
@property (copy, nullable) BOOL (^pasteInterceptor)(void);

// Screen housekeeping, for the menu commands.
- (void)clearScreen; // screen and scrollback
- (void)clearScrollback;
- (void)resetTerminal; // full VT reset, then the theme is reapplied
// Everything in the scrollback and on screen, as text.
- (void)fetchTextWithCompletion:(void (^)(NSString *text))completion;

@end
