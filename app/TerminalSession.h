//
//  TerminalSession.h
//  iSH
//
//  A shell process plus the Terminal it is attached to. Sessions live in the
//  TerminalSessionStore independently of any view or window showing them.
//

#import <Foundation/Foundation.h>
#import "Terminal.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TerminalSessionState) {
    TerminalSessionStateRunning,
    TerminalSessionStateExited, // the shell exited; the terminal still shows its last output
    TerminalSessionStateClosed, // removed from the store
};

@interface TerminalSession : NSObject

@property (readonly) NSUUID *uuid; // same as terminal.uuid
@property (readonly) Terminal *terminal;
@property (readonly) int pid;
@property (readonly) TerminalSessionState state;
@property (readonly) int exitCode; // valid once state is Exited
@property (readonly) NSUInteger number; // 1-based, in order of creation, for the default title
@property (readonly) NSDate *startDate;

// Set by the user (tab rename). nil means use the default title.
@property (nonatomic, copy, nullable) NSString *title;
@property (readonly) NSString *displayTitle;

// The shell's working directory, or nil if it cannot be determined (e.g. after
// the shell exited).
@property (readonly, nullable) NSString *currentDirectory;
// Whether a shell, rather than a job like vim or ssh, owns the terminal: typed
// text goes to a prompt.
@property (readonly) BOOL shellIsForeground;

@end

// Posted on the main thread with the session as the object whenever its state
// or title changes.
extern NSNotificationName const TerminalSessionDidChangeNotification;

@interface TerminalSessionStore : NSObject

+ (instancetype)shared;

// Every session that has not been closed, in creation order.
@property (readonly) NSArray<TerminalSession *> *sessions;

// Starts the configured launch command in a new pseudo terminal. Returns nil
// and sets *error (a negative errno) on failure. Main thread only.
- (nullable TerminalSession *)startSessionWithError:(int *_Nullable)error;

- (nullable TerminalSession *)sessionWithUUID:(NSUUID *)uuid;

// Hangs up the terminal (the foreground job gets SIGHUP) and forgets the
// session. Idempotent.
- (void)closeSession:(TerminalSession *)session;

@end

NS_ASSUME_NONNULL_END
