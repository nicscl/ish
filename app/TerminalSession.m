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

- (NSString *)currentDirectory {
#if !ISH_LINUX
    if (self.state != TerminalSessionStateRunning)
        return nil;
    // login forks the shell, so the process that owns the terminal (the shell, or
    // a job it started from the same directory) is the one to ask; the session's
    // own process is login, whose directory never changes.
    int fg_group = self.terminal.foregroundProcessGroup;
    NSString *directory = nil;
    lock(&pids_lock);
    struct task *task = pid_get_task(fg_group != 0 ? fg_group : self.pid);
    if (task != NULL && task->fs != NULL) {
        char path[MAX_PATH + 1];
        lock(&task->fs->lock);
        int err = generic_getpath(task->fs->pwd, path);
        unlock(&task->fs->lock);
        if (err >= 0)
            directory = [NSString stringWithUTF8String:path];
    }
    unlock(&pids_lock);
    return directory;
#else
    return nil;
#endif
}

- (BOOL)shellIsForeground {
#if !ISH_LINUX
    if (self.state != TerminalSessionStateRunning)
        return NO;
    // login forks the shell into its own process group, so the shell's pid is not
    // known; go by what the foreground group's leader is running instead.
    int fg_group = self.terminal.foregroundProcessGroup;
    if (fg_group == 0)
        return NO;
    static NSSet<NSString *> *shells;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shells = [NSSet setWithArray:@[@"sh", @"ash", @"bash", @"dash", @"zsh", @"fish", @"ksh", @"mksh", @"busybox"]];
    });
    lock(&pids_lock);
    struct task *task = pid_get_task(fg_group);
    NSString *comm = task != NULL ? [NSString stringWithUTF8String:task->comm] : nil;
    unlock(&pids_lock);
    return comm != nil && [shells containsObject:comm];
#else
    return YES; // can't tell, so don't get in the way
#endif
}

@end

@interface TerminalSessionStore ()
@property NSMutableArray<TerminalSession *> *mutableSessions;
@property NSUInteger nextNumber;
// pids of every process started here that has not been reaped yet, including
// those of sessions already closed
@property NSMutableSet<NSNumber *> *livePids;
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
        self.livePids = [NSMutableSet new];
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
    [self.livePids addObject:@(pid)];
#if !ISH_LINUX
    task_start(current);
    // The task now runs on its own thread. If main kept pointing at it, signals sent
    // from main (e.g. SIGHUP on close) would take the "signalling myself" path and
    // not wake the task's thread.
    current = NULL;
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
    if (![self.livePids containsObject:@(pid)])
        return; // not ours (e.g. something init spawned itself)
    [self.livePids removeObject:@(pid)];
    // Sessions are children of init, and init does not wait for them. The zombie holds
    // a reference to its controlling terminal, so it must be reaped here (whether or not
    // its tab is still open) or the pty, and with it the Terminal and its web view,
    // live forever.
    reap_init_child(pid);
    for (TerminalSession *session in self.mutableSessions) {
        if (session.pid == pid && session.state == TerminalSessionStateRunning) {
            session.exitCode = code;
            session.state = TerminalSessionStateExited;
            // Not destroy: the tab stays visible, so output still in flight must be rendered.
            [session.terminal hangup];
            [session notifyChanged];
            return;
        }
    }
}
#endif

@end
