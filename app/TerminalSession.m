//
//  TerminalSession.m
//  iSH
//

#import "TerminalSession.h"
#import "AppDelegate.h"
#import "UserPreferences.h"
#import "LinuxInterop.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "fs/devices.h"

NSNotificationName const TerminalSessionDidChangeNotification = @"TerminalSessionDidChangeNotification";

@interface TerminalSession ()
@property Terminal *terminal;
@property int pid;
@property TerminalSessionState state;
@property int exitCode;
@property NSUInteger number;
@property NSDate *startDate;
@end

@implementation TerminalSession

- (NSUUID *)uuid {
    return self.terminal.uuid;
}

- (NSString *)displayTitle {
    if (self.title.length > 0)
        return self.title;
    return [NSString stringWithFormat:@"Shell %lu", (unsigned long) self.number];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    [self notifyChanged];
}

- (void)notifyChanged {
    NSAssert(NSThread.isMainThread, @"session changes are main thread only");
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalSessionDidChangeNotification object:self];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TerminalSession %@ pid=%d state=%ld>", self.displayTitle, self.pid, (long) self.state];
}

@end

@interface TerminalSessionStore ()
@property NSMutableArray<TerminalSession *> *mutableSessions;
@property NSUInteger nextNumber;
@end

@implementation TerminalSessionStore

+ (instancetype)shared {
    static TerminalSessionStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [TerminalSessionStore new];
    });
    return store;
}

- (instancetype)init {
    if (self = [super init]) {
        self.mutableSessions = [NSMutableArray new];
        self.nextNumber = 1;
#if !ISH_LINUX
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(processExited:)
                                                   name:ProcessExitedNotification
                                                 object:nil];
#endif
    }
    return self;
}

- (NSArray<TerminalSession *> *)sessions {
    return [self.mutableSessions copy];
}

- (TerminalSession *)sessionWithUUID:(NSUUID *)uuid {
    for (TerminalSession *session in self.mutableSessions) {
        if ([session.uuid isEqual:uuid])
            return session;
    }
    return nil;
}

#if !ISH_LINUX
// Creates the pty and the process, leaving it ready for task_start. Returns a negative errno.
static int start_process(NSArray<NSString *> *command, Terminal **terminalOut) {
    int err = become_new_init_child();
    if (err < 0)
        return err;
    struct tty *tty;
    Terminal *terminal = [Terminal createPseudoTerminal:&tty];
    if (terminal == nil) {
        NSCAssert(IS_ERR(tty), @"tty should be error");
        return (int) PTR_ERR(tty);
    }
    *terminalOut = terminal;
    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0)
        return err;
    tty_release(tty);

    char argv[4096];
    [Terminal convertCommand:command toArgs:argv limitSize:sizeof(argv)];
    const char *envp = "TERM=xterm-256color\0";
    err = do_execve(command[0].UTF8String, command.count, argv, envp);
    if (err < 0)
        return err;
    return current->pid;
}
#else
static int start_process(NSArray<NSString *> *command, Terminal **terminalOut) {
    const char *argv_arr[command.count + 1];
    for (NSUInteger i = 0; i < command.count; i++)
        argv_arr[i] = command[i].UTF8String;
    argv_arr[command.count] = NULL;
    const char *envp_arr[] = {
        "TERM=xterm-256color",
        NULL,
    };
    const char *const *argv = argv_arr;
    const char *const *envp = envp_arr;
    __block Terminal *terminal = nil;
    __block int sessionPid = 0;
    __block int err = 1;
    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(argv[0], argv, envp, ^(int retval, int pid, nsobj_t term) {
            err = retval;
            if (term)
                terminal = CFBridgingRelease(term);
            sessionPid = pid;
            done();
        });
    });
    NSCAssert(err <= 0, @"session start did not finish??");
    if (err < 0)
        return err;
    *terminalOut = terminal;
    return sessionPid;
}
#endif

- (TerminalSession *)startSessionWithError:(int *)errorOut {
    NSAssert(NSThread.isMainThread, @"sessions are started from the main thread");
    Terminal *terminal = nil;
    int pid = start_process(UserPreferences.shared.launchCommand, &terminal);
    if (pid < 0) {
        if (terminal != nil)
            [terminal destroy];
        if (errorOut != NULL)
            *errorOut = pid;
        return nil;
    }

    TerminalSession *session = [TerminalSession new];
    session.terminal = terminal;
    session.pid = pid;
    session.state = TerminalSessionStateRunning;
    session.number = self.nextNumber++;
    session.startDate = [NSDate date];
    // Register before the process can run, so an immediately exiting command is still matched.
    [self.mutableSessions addObject:session];
#if !ISH_LINUX
    task_start(current);
#endif
    return session;
}

- (void)closeSession:(TerminalSession *)session {
    NSAssert(NSThread.isMainThread, @"sessions are closed from the main thread");
    if (session.state == TerminalSessionStateClosed)
        return;
    [session.terminal destroy];
    session.state = TerminalSessionStateClosed;
    [self.mutableSessions removeObject:session];
    [session notifyChanged];
}

#if !ISH_LINUX
- (void)processExited:(NSNotification *)notif {
    int pid = [notif.userInfo[@"pid"] intValue];
    int code = [notif.userInfo[@"code"] intValue];
    for (TerminalSession *session in self.mutableSessions) {
        if (session.pid == pid && session.state == TerminalSessionStateRunning) {
            session.exitCode = code;
            session.state = TerminalSessionStateExited;
            [session.terminal destroy];
            [session notifyChanged];
            return;
        }
    }
}
#endif

@end
