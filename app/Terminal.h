//
//  Terminal.h
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

struct tty;

// WKUserContentController retains its message handlers, so anything that owns
// the web view must register through this to avoid a retain cycle.
@interface WeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
- (instancetype)initWithHandler:(id <WKScriptMessageHandler>)handler;
@end

@interface Terminal : NSObject

+ (Terminal *)terminalWithType:(int)type number:(int)number;
#if !ISH_LINUX
// Returns a strong struct tty and a Terminal that has a weak reference to the same tty
+ (Terminal *)createPseudoTerminal:(struct tty **)tty;
#endif

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *uuid;

+ (void)convertCommand:(NSArray<NSString *> *)command toArgs:(char *)argv limitSize:(size_t)maxSize;

- (int)sendOutput:(const void *)buf length:(int)len;
- (void)sendInput:(NSData *)input;

- (NSString *)arrow:(char)direction;

// Make this terminal no longer be the singleton terminal with its type and number. Will happen eventually if all references go away, but sometimes you want it to happen now.
// Hangs up the tty (the shell sees EIO/EOF), drops any output still waiting to
// be rendered and unblocks a writer waiting for it. Safe to call more than once.
- (void)destroy;

@property (readonly) WKWebView *webView;
@property (nonatomic) BOOL enableVoiceOverAnnounce;
// Use KVO on this
@property (readonly) BOOL loaded;

@end

extern struct tty_driver ios_console_driver;
