//
//  ViewController.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import "TerminalViewController.h"
#import "AppDelegate.h"
#import "TerminalView.h"
#import "TerminalSession.h"
#import "TabBarView.h"
#import "MainMenu.h"
#import "BackgroundKeepAlive.h"
#import "SceneDelegate.h"
#import "BarButton.h"
#import "ArrowBarButton.h"
#import "UserPreferences.h"
#import "AboutViewController.h"
#import "CurrentRoot.h"
#import "NSObject+SaneKVO.h"
#import "LinuxInterop.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/signal.h"
#include "fs/devices.h"

@interface TerminalViewController () <UIGestureRecognizerDelegate, TabBarViewDelegate>

@property UITapGestureRecognizer *tapRecognizer;
@property (weak, nonatomic) IBOutlet TerminalView *termView;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bottomConstraint;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *termTop;
@property TabBarView *tabBar;

@property (weak, nonatomic) IBOutlet UIButton *tabKey;
@property (weak, nonatomic) IBOutlet UIButton *controlKey;
@property (weak, nonatomic) IBOutlet UIButton *escapeKey;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barButtons;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barControls;

@property (weak, nonatomic) IBOutlet UIInputView *barView;
@property (weak, nonatomic) IBOutlet UIStackView *bar;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTop;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barBottom;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barLeading;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTrailing;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barButtonWidth;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barHeight;

@property (weak, nonatomic) IBOutlet UIButton *pasteButton;

// Sessions shown in this window, in tab order. All of them are also in the TerminalSessionStore.
@property NSMutableArray<TerminalSession *> *tabs;
@property (nonatomic) TerminalSession *selectedSession;
// The selected tab's terminal (self.terminal differs from this while a console is shown).
@property (readonly) Terminal *sessionTerminal;

@property BOOL ignoreKeyboardMotion;
@property (nonatomic) BOOL hasExternalKeyboard;

@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];

#if !ISH_LINUX
    int bootError = [AppDelegate bootError];
    if (bootError < 0) {
        NSString *message = [NSString stringWithFormat:@"could not boot"];
        NSString *subtitle = [NSString stringWithFormat:@"error code %d", bootError];
        if (bootError == _EINVAL)
            subtitle = [subtitle stringByAppendingString:@"\n(try reinstalling the app, see release notes for details)"];
        [self showMessage:message subtitle:subtitle];
        NSLog(@"boot failed with code %d", bootError);
    }
#endif

    self.tabBar = [[TabBarView alloc] initWithFrame:CGRectZero];
    self.tabBar.delegate = self;
    self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tabBar];
    self.termTop.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.tabBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tabBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tabBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.termView.topAnchor constraintEqualToAnchor:self.tabBar.bottomAnchor],
    ]];
    [self tabsDidChange];

    self.terminal = self.terminal;
    [self.termView becomeFirstResponder];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(_updateBadge)
                   name:FsUpdatedNotification
                 object:nil];


    [self _updateStyleFromPreferences:NO];
    
    self.barView.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:@"Hide Keyboard" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
        return [self.termView resignFirstResponder];
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        self.barHeight.constant = 36;
    } else {
        self.barHeight.constant = 43;
    }
    
    // SF Symbols is cool
    if (@available(iOS 13, *)) {
        [self.pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
        
        [self.tabKey setTitle:nil forState:UIControlStateNormal];
        [self.tabKey setImage:[UIImage systemImageNamed:@"arrow.right.to.line.alt"] forState:UIControlStateNormal];
        [self.controlKey setTitle:nil forState:UIControlStateNormal];
        [self.controlKey setImage:[UIImage systemImageNamed:@"control"] forState:UIControlStateNormal];
        [self.escapeKey setTitle:nil forState:UIControlStateNormal];
        [self.escapeKey setImage:[UIImage systemImageNamed:@"escape"] forState:UIControlStateNormal];
    }
    
    [UserPreferences.shared observe:@[@"hideStatusBar"] options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsStatusBarAppearanceUpdate];
        });
    }];
    [UserPreferences.shared observe:@[@"colorScheme", @"theme", @"hideExtraKeysWithExternalKeyboard"]
                            options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyleFromPreferences:YES];
        });
    }];
    [self _updateBadge];
}

- (void)awakeFromNib {
    [super awakeFromNib];
    self.tabs = [NSMutableArray new];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sessionDidChange:)
                                               name:TerminalSessionDidChangeNotification
                                             object:nil];
#if ISH_LINUX
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(kernelPanicked:)
                                               name:KernelPanicNotification
                                             object:nil];
#endif
}

- (void)viewDidAppear:(BOOL)animated {
    [AppDelegate maybePresentStartupMessageOnViewController:self];
    [super viewDidAppear:animated];
}

- (void)startNewSession {
    [self startNewSessionAtIndex:self.tabs.count];
}

// Opens a shell in a new tab at the given position and selects it. Returns nil (after
// telling the user) if the shell could not be started.
- (TerminalSession *)startNewSessionAtIndex:(NSUInteger)index {
    int err = 0;
    TerminalSession *session = [TerminalSessionStore.shared startSessionWithError:&err];
    if (session == nil) {
        [self showMessage:@"could not start session"
                 subtitle:[NSString stringWithFormat:@"error code %d", err]];
        return nil;
    }
    [self.tabs insertObject:session atIndex:MIN(index, self.tabs.count)];
    self.selectedSession = session;
    return session;
}

- (void)reconnectSessionsFromTerminalUUIDs:(NSArray<NSUUID *> *)uuids selected:(NSUUID *)selected {
    TerminalSessionStore *store = TerminalSessionStore.shared;
    TerminalSession *toSelect = nil;
    for (NSUUID *uuid in uuids) {
        TerminalSession *session = [store sessionWithUUID:uuid];
        if (session == nil || [self.tabs containsObject:session])
            continue;
        [self.tabs addObject:session];
        if ([uuid isEqual:selected])
            toSelect = session;
    }
    if (self.tabs.count == 0) {
        [self startNewSession];
        return;
    }
    self.selectedSession = toSelect ?: self.tabs.firstObject;
}

- (NSArray<NSUUID *> *)tabTerminalUUIDs {
    NSMutableArray<NSUUID *> *uuids = [NSMutableArray new];
    for (TerminalSession *session in self.tabs)
        [uuids addObject:session.uuid];
    return uuids;
}

- (NSUUID *)sessionTerminalUUID {
    return self.selectedSession.uuid;
}

- (Terminal *)sessionTerminal {
    return self.selectedSession.terminal;
}

#pragma mark Tabs

- (void)setSelectedSession:(TerminalSession *)session {
    NSAssert(session == nil || [self.tabs containsObject:session], @"selecting a session that is not a tab");
    _selectedSession = session;
    self.terminal = session.terminal;
    [self tabsDidChange];
}

- (void)selectTabAtIndex:(NSUInteger)index {
    if (index < self.tabs.count)
        self.selectedSession = self.tabs[index];
}

- (void)selectNeighborTab:(NSInteger)offset {
    if (self.tabs.count < 2)
        return;
    NSInteger index = (NSInteger) [self.tabs indexOfObject:self.selectedSession];
    NSInteger count = (NSInteger) self.tabs.count;
    [self selectTabAtIndex:(NSUInteger) (((index + offset) % count + count) % count)];
}

- (void)closeTab:(TerminalSession *)session {
    NSUInteger index = [self.tabs indexOfObject:session];
    if (index == NSNotFound)
        return;
    [self.tabs removeObjectAtIndex:index];
    [TerminalSessionStore.shared closeSession:session];
    if (self.tabs.count == 0) {
        // A window with no shell in it is useless, so start a fresh one in place.
        [self startNewSession];
    } else if (session == self.selectedSession) {
        [self selectTabAtIndex:MIN(index, self.tabs.count - 1)];
    } else {
        [self tabsDidChange];
    }
}

- (void)sessionDidChange:(NSNotification *)notif {
    TerminalSession *session = notif.object;
    if (![self.tabs containsObject:session])
        return;
    if (session.state == TerminalSessionStateClosed) {
        // Closed by someone else (another window, or the app delegate).
        [self closeTab:session];
        return;
    }
    if (session.state == TerminalSessionStateExited && self.tabs.count == 1) {
        // The only shell exited: replace it, as the app has always done on iPhone, unless
        // it died right after starting, which would just loop.
        if ([NSDate.date timeIntervalSinceDate:session.startDate] > 1) {
            [self closeTab:session];
            return;
        }
    }
    [self tabsDidChange];
}

// Called whenever the tab list, the selection or a tab's state/title changes.
- (void)tabsDidChange {
    NSUInteger selected = self.selectedSession ? [self.tabs indexOfObject:self.selectedSession] : NSNotFound;
    [self.tabBar setSessions:self.tabs selectedIndex:selected];
}

- (void)tabBar:(TabBarView *)tabBar didSelectTabAtIndex:(NSUInteger)index {
    [self selectTabAtIndex:index];
    [self.termView becomeFirstResponder];
}

- (void)tabBar:(TabBarView *)tabBar didRequestCloseTabAtIndex:(NSUInteger)index {
    if (index < self.tabs.count)
        [self closeTab:self.tabs[index]];
}

- (void)tabBar:(TabBarView *)tabBar didRequestCloseOtherTabsAtIndex:(NSUInteger)index {
    if (index >= self.tabs.count)
        return;
    TerminalSession *keep = self.tabs[index];
    self.selectedSession = keep;
    // Snapshot first: closeTab: mutates tabs.
    for (TerminalSession *session in [self.tabs copy]) {
        if (session != keep)
            [self closeTab:session];
    }
    [self.termView becomeFirstResponder];
}

- (void)tabBarDidRequestNewTab:(TabBarView *)tabBar {
    [self startNewSession];
    [self.termView becomeFirstResponder];
}

- (UIMenu *)commandsMenuForTabBar:(TabBarView *)tabBar {
    return [MainMenu commandsMenu];
}

- (void)tabBar:(TabBarView *)tabBar didRequestRenameTabAtIndex:(NSUInteger)index {
    if (index >= self.tabs.count)
        return;
    TerminalSession *session = self.tabs[index];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Tab" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = session.title;
        textField.placeholder = session.displayTitle;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    __weak TerminalViewController *weakSelf = self;
    UIAlertAction *rename = [UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *title = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        session.title = title.length > 0 ? title : nil;
        [weakSelf.termView becomeFirstResponder];
    }];
    [alert addAction:rename];
    alert.preferredAction = rename; // Return in the text field confirms
    [self presentViewController:alert animated:YES completion:nil];
}

#if ISH_LINUX
- (void)kernelPanicked:(NSNotification *)notif {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"panik" message:notif.userInfo[@"message"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"k" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)showMessage:(NSString *)message subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:message message:subtitle preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"k"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == [UserPreferences shared]) {
        [self _updateStyleFromPreferences:YES];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_updateStyleFromPreferences:(BOOL)animated {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    NSTimeInterval duration = animated ? 0.1 : 0;
    [UIView animateWithDuration:duration animations:^{
        self.view.backgroundColor = [[UIColor alloc] ish_initWithHexString:UserPreferences.shared.palette.backgroundColor];
        [self.tabBar setBackgroundColor:self.view.backgroundColor
                        foregroundColor:[[UIColor alloc] ish_initWithHexString:UserPreferences.shared.palette.foregroundColor]];
        UIKeyboardAppearance keyAppearance = UserPreferences.shared.keyboardAppearance;
        self.termView.keyboardAppearance = keyAppearance;
        for (BarButton *button in self.barButtons) {
            button.keyAppearance = keyAppearance;
        }
        UIColor *tintColor = keyAppearance == UIKeyboardAppearanceLight ? UIColor.blackColor : UIColor.whiteColor;
        for (UIControl *control in self.barControls) {
            control.tintColor = tintColor;
        }
    }];
    UIView *oldBarView = self.termView.inputAccessoryView;
    if (UserPreferences.shared.hideExtraKeysWithExternalKeyboard && self.hasExternalKeyboard) {
        self.termView.inputAccessoryView = nil;
    } else {
        self.termView.inputAccessoryView = self.barView;
    }
    if (self.termView.inputAccessoryView != oldBarView && self.termView.isFirstResponder) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ignoreKeyboardMotion = YES; // avoid infinite recursion
            [self.termView reloadInputViews];
            self.ignoreKeyboardMotion = NO;
        });
    }
}
- (void)_updateStyleAnimated {
    [self _updateStyleFromPreferences:YES];
}

- (void)_updateBadge {
    self.tabBar.showsCommandsBadge = FsNeedsRepositoryUpdate();
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UserPreferences.shared.statusBarStyle;
}

- (BOOL)prefersStatusBarHidden {
    return UserPreferences.shared.hideStatusBar;
}

- (void)keyboardDidSomething:(NSNotification *)notification {
    if (self.ignoreKeyboardMotion)
        return;

    CGRect screenKeyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIScreen *screen = UIScreen.mainScreen;
    // notification.object is nil before iOS 16.1 and the correct UIScreen after iOS 16.1
    if (notification.object != nil)
        screen = notification.object;
    CGRect keyboardFrame = [self.view convertRect:screenKeyboardFrame fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectEqualToRect(keyboardFrame, CGRectZero))
        return;
    CGRect intersection = CGRectIntersection(keyboardFrame, self.view.bounds);
    keyboardFrame = intersection;
    NSLog(@"%@ %@", notification.name, @(keyboardFrame));
    self.hasExternalKeyboard = keyboardFrame.size.height < 100;
    CGFloat pad = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardFrame);
    // The keyboard appears to be undocked. This means it can either be split or
    // truly floating. In the former case we want to keep the pad, but in the
    // latter we should fall back to the input accessory view instead of the
    // keyboard.
    if (pad != keyboardFrame.size.height && keyboardFrame.size.width != UIScreen.mainScreen.bounds.size.width) {
        pad = MAX(self.view.safeAreaInsets.bottom, self.termView.inputAccessoryView.frame.size.height);
    }
    // NSLog(@"pad %f", pad);
    self.bottomConstraint.constant = pad;

    BOOL initialLayout = self.termView.needsUpdateConstraints;
    [self.view setNeedsUpdateConstraints];
    if (!initialLayout) {
        // if initial layout hasn't happened yet, the terminal view is going to be at a really weird place, so animating it is going to look really bad
        NSNumber *interval = notification.userInfo[UIKeyboardAnimationDurationUserInfoKey];
        NSNumber *curve = notification.userInfo[UIKeyboardAnimationCurveUserInfoKey];
        [UIView animateWithDuration:interval.doubleValue
                              delay:0
                            options:curve.integerValue << 16
                         animations:^{
                             [self.view layoutIfNeeded];
                         }
                         completion:nil];
    }
}

- (void)setHasExternalKeyboard:(BOOL)hasExternalKeyboard {
    _hasExternalKeyboard = hasExternalKeyboard;
    [self _updateStyleFromPreferences:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"embed"]) {
        // You might want to check if this is your embed segue here
        // in case there are other segues triggered from this view controller.
        segue.destinationViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    // Hack to resolve a layering mismatch between the UI and preferences.
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // Ensure that the relevant things listening for this will update.
            UserPreferences.shared.colorScheme = UserPreferences.shared.colorScheme;
        }
    }
}

#pragma mark Bar

- (IBAction)showAbout:(id)sender {
    UINavigationController *navigationController = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
    if ([sender isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *recognizer = sender;
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            AboutViewController *aboutViewController = (AboutViewController *) navigationController.topViewController;
            aboutViewController.includeDebugPanel = YES;
        } else {
            return;
        }
    }
    [self presentViewController:navigationController animated:YES completion:nil];
    [self.termView resignFirstResponder];
}

- (void)resizeBar {
    CGSize bar = self.barView.bounds.size;
    // set sizing parameters on bar
    // numbers stolen from iVim and modified somewhat
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        // phone
        [self setBarHorizontalPadding:6 verticalPadding:6 buttonWidth:32];
    } else if (bar.width >= 450) {
        // wide ipad
        [self setBarHorizontalPadding:15 verticalPadding:8 buttonWidth:43];
    } else {
        // narrow ipad (slide over)
        [self setBarHorizontalPadding:10 verticalPadding:8 buttonWidth:36];
    }
    [UIView performWithoutAnimation:^{
        [self.barView layoutIfNeeded];
    }];
}

- (void)setBarHorizontalPadding:(CGFloat)horizontal verticalPadding:(CGFloat)vertical buttonWidth:(CGFloat)buttonWidth {
    self.barLeading.constant = self.barTrailing.constant = horizontal;
    self.barTop.constant = self.barBottom.constant = vertical;
    self.barButtonWidth.constant = buttonWidth;
}

- (IBAction)pressEscape:(id)sender {
    [self pressKey:@"\x1b"];
}
- (IBAction)pressTab:(id)sender {
    [self pressKey:@"\t"];
}
- (void)pressKey:(NSString *)key {
    [self.termView insertText:key];
}

- (IBAction)pressControl:(id)sender {
    self.controlKey.selected = !self.controlKey.selected;
}
    
- (IBAction)pressArrow:(ArrowBarButton *)sender {
    switch (sender.direction) {
        case ArrowUp: [self pressKey:[self.terminal arrow:'A' modifiers:sender.modifiers]]; break;
        case ArrowDown: [self pressKey:[self.terminal arrow:'B' modifiers:sender.modifiers]]; break;
        case ArrowLeft: [self pressKey:[self.terminal arrow:'D' modifiers:sender.modifiers]]; break;
        case ArrowRight: [self pressKey:[self.terminal arrow:'C' modifiers:sender.modifiers]]; break;
        case ArrowNone: break;
    }
}

#pragma mark Commands

static NSString *ShellQuoted(NSString *string) {
    return [NSString stringWithFormat:@"'%@'", [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// Reached from the main menu, the tab strip's ⋯ menu and key equivalents (see MainMenu).

- (void)switchTerminal:(UICommand *)sender {
    int i = [sender.propertyList intValue];
    if (i == 7)
        self.terminal = self.sessionTerminal;
    else
        self.terminal = [Terminal terminalWithType:TTY_CONSOLE_MAJOR number:i];
}

- (void)increaseFontSize:(id)sender {
    self.termView.overrideFontSize = self.termView.effectiveFontSize + 1;
}
- (void)decreaseFontSize:(id)sender {
    self.termView.overrideFontSize = self.termView.effectiveFontSize - 1;
}
- (void)resetFontSize:(id)sender {
    self.termView.overrideFontSize = 0;
}

// Shortcuts that are not menu items: a second binding for Bigger (the unshifted key)
// and Ctrl+Tab for cycling tabs, as in browsers.
- (NSArray<UIKeyCommand *> *)keyCommands {
    static NSArray<UIKeyCommand *> *commands = nil;
    if (commands == nil) {
        commands = @[
            [UIKeyCommand keyCommandWithInput:@"=" modifierFlags:UIKeyModifierCommand action:@selector(increaseFontSize:)],
            [UIKeyCommand keyCommandWithInput:@"\t" modifierFlags:UIKeyModifierControl action:@selector(nextTab:)],
            [UIKeyCommand keyCommandWithInput:@"\t" modifierFlags:UIKeyModifierControl | UIKeyModifierShift action:@selector(previousTab:)],
        ];
        for (UIKeyCommand *command in commands)
            command.wantsPriorityOverSystemBehavior = YES;
    }
    return commands;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(paste:))
        return UIPasteboard.generalPasteboard.hasStrings;
    return [super canPerformAction:action withSender:sender];
}

// Menu state that depends on the tabs, windows and preferences of the moment.
- (void)validateCommand:(UICommand *)command {
    SEL action = command.action;
    NSUInteger count = self.tabs.count;
    BOOL running = self.selectedSession.state == TerminalSessionStateRunning;
    UserPreferences *prefs = UserPreferences.shared;
    if (action == @selector(selectTabByNumber:)) {
        NSUInteger index = [command.propertyList unsignedIntegerValue];
        if (index < count) {
            command.title = self.tabs[index].displayTitle;
            command.state = self.tabs[index] == self.selectedSession ? UIMenuElementStateOn : UIMenuElementStateOff;
            command.attributes = 0;
        } else {
            command.attributes = UIMenuElementAttributesHidden;
        }
    } else if (action == @selector(closeOtherTabs:) || action == @selector(nextTab:) || action == @selector(previousTab:) ||
               action == @selector(moveTabLeft:) || action == @selector(moveTabRight:)) {
        command.attributes = count < 2 ? UIMenuElementAttributesDisabled : 0;
    } else if (action == @selector(newWindow:) || action == @selector(closeWindow:) ||
               action == @selector(moveTabToNewWindow:) || action == @selector(mergeAllWindows:)) {
        if (!UIApplication.sharedApplication.supportsMultipleScenes) {
            command.attributes = UIMenuElementAttributesHidden;
        } else {
            BOOL others = ConnectedTerminalViewControllers().count > 1;
            BOOL enabled = action == @selector(newWindow:) ||
                (action == @selector(moveTabToNewWindow:) && count > 1) ||
                (action == @selector(mergeAllWindows:) && others) ||
                (action == @selector(closeWindow:) && UIApplication.sharedApplication.openSessions.count > 1);
            command.attributes = enabled ? 0 : UIMenuElementAttributesDisabled;
        }
    } else if (action == @selector(duplicateTab:) || action == @selector(copyCurrentDirectory:) ||
               action == @selector(mountFolder:) || action == @selector(runSavedCommand:)) {
        command.attributes = running ? 0 : UIMenuElementAttributesDisabled;
    } else if (action == @selector(selectTheme:)) {
        command.state = [command.propertyList isEqual:prefs.theme.name] ? UIMenuElementStateOn : UIMenuElementStateOff;
    } else if (action == @selector(selectColorScheme:)) {
        command.state = [command.propertyList integerValue] == prefs.colorScheme ? UIMenuElementStateOn : UIMenuElementStateOff;
    } else if (action == @selector(toggleExtraKeys:)) {
        command.state = prefs.hideExtraKeysWithExternalKeyboard ? UIMenuElementStateOff : UIMenuElementStateOn;
    } else if (action == @selector(toggleStatusBar:)) {
        command.state = prefs.hideStatusBar ? UIMenuElementStateOn : UIMenuElementStateOff;
    } else if (action == @selector(toggleKeepAlive:)) {
        BackgroundKeepAlive *keepAlive = BackgroundKeepAlive.shared;
        command.state = keepAlive.enabled && !keepAlive.denied ? UIMenuElementStateOn : UIMenuElementStateOff;
    } else if (action == @selector(switchTerminal:)) {
        int number = [command.propertyList intValue];
        BOOL current = number == 7 ? self.terminal == self.sessionTerminal
                                   : self.terminal == [Terminal terminalWithType:TTY_CONSOLE_MAJOR number:number];
        command.state = current ? UIMenuElementStateOn : UIMenuElementStateOff;
    }
}

#pragma mark Shell menu

- (void)newTab:(id)sender {
    [self startNewSession];
}

- (void)newWindow:(id)sender {
    [UIApplication.sharedApplication requestSceneSessionActivation:nil userActivity:nil options:nil errorHandler:nil];
}

// The new shell logs in at home like any other; it is then told to cd to where the
// duplicated one was, visibly, since login leaves no other way to pick a directory.
- (void)duplicateTab:(id)sender {
    TerminalSession *session = self.selectedSession;
    if (session == nil)
        return;
    NSString *directory = session.currentDirectory;
    TerminalSession *copy = [self startNewSessionAtIndex:[self.tabs indexOfObject:session] + 1];
    if (copy != nil && directory != nil)
        [self typeCommand:[@"cd " stringByAppendingString:ShellQuoted(directory)] intoSession:copy attempts:50];
}

- (void)renameCurrentTab:(id)sender {
    NSUInteger index = [self.tabs indexOfObject:self.selectedSession];
    if (index != NSNotFound)
        [self tabBar:self.tabBar didRequestRenameTabAtIndex:index];
}

// A fresh shell in the same tab: same position and name.
- (void)restartShell:(id)sender {
    TerminalSession *old = self.selectedSession;
    NSUInteger index = [self.tabs indexOfObject:old];
    if (index == NSNotFound)
        return;
    int err = 0;
    TerminalSession *session = [TerminalSessionStore.shared startSessionWithError:&err];
    if (session == nil) {
        [self showMessage:@"could not start session" subtitle:[NSString stringWithFormat:@"error code %d", err]];
        return;
    }
    session.title = old.title;
    [self.tabs replaceObjectAtIndex:index withObject:session];
    [TerminalSessionStore.shared closeSession:old];
    self.selectedSession = session;
}

- (void)resetTerminal:(id)sender {
    [self.termView resetTerminal];
}

- (void)sendBytes:(const char *)bytes {
    [self.terminal sendInput:[NSData dataWithBytes:bytes length:strlen(bytes)]];
}
- (void)sendInterrupt:(id)sender {
    [self sendBytes:"\x03"];
}
- (void)sendEndOfFile:(id)sender {
    [self sendBytes:"\x04"];
}
- (void)sendSuspend:(id)sender {
    [self sendBytes:"\x1a"];
}
- (void)killForegroundJob:(id)sender {
    [self.terminal sendSignalToForegroundJob:SIGKILL_];
}

- (void)exportScrollback:(id)sender {
    NSString *name = [self.selectedSession.displayTitle stringByAppendingPathExtension:@"txt"] ?: @"scrollback.txt";
    [self.termView fetchTextWithCompletion:^(NSString *text) {
        // hterm pads the screen with empty rows below the cursor; drop them.
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        NSError *error = nil;
        if (![[trimmed stringByAppendingString:@"\n"] writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            [self showMessage:@"could not export scrollback" subtitle:error.localizedDescription];
            return;
        }
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
        [self presentViewController:picker animated:YES completion:nil];
    }];
}

- (void)closeCurrentTab:(id)sender {
    if (self.selectedSession != nil)
        [self closeTab:self.selectedSession];
}

- (void)closeOtherTabs:(id)sender {
    NSUInteger index = [self.tabs indexOfObject:self.selectedSession];
    if (index != NSNotFound)
        [self tabBar:self.tabBar didRequestCloseOtherTabsAtIndex:index];
}

- (void)closeWindow:(id)sender {
    if (self.sceneSession != nil)
        [UIApplication.sharedApplication requestSceneSessionDestruction:self.sceneSession options:nil errorHandler:nil];
}

#pragma mark Edit menu

- (void)paste:(id)sender {
    [self.termView paste:sender];
}
- (void)clearScreen:(id)sender {
    [self.termView clearScreen];
}
- (void)clearScrollback:(id)sender {
    [self.termView clearScrollback];
}

#pragma mark View menu

- (void)selectTheme:(UICommand *)sender {
    Theme *theme = [Theme themeForName:sender.propertyList includingDefaultThemes:YES];
    if (theme != nil)
        UserPreferences.shared.theme = theme;
}
- (void)selectColorScheme:(UICommand *)sender {
    UserPreferences.shared.colorScheme = [sender.propertyList integerValue];
}
- (void)toggleExtraKeys:(id)sender {
    UserPreferences.shared.hideExtraKeysWithExternalKeyboard = !UserPreferences.shared.hideExtraKeysWithExternalKeyboard;
}
- (void)toggleStatusBar:(id)sender {
    UserPreferences.shared.hideStatusBar = !UserPreferences.shared.hideStatusBar;
}

- (void)toggleKeepAlive:(id)sender {
    BackgroundKeepAlive *keepAlive = BackgroundKeepAlive.shared;
    if (keepAlive.denied) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Location Access Needed"
                                                                       message:@"iSH stays running in the background by receiving coarse location updates. Allow location access for iSH in Settings."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        keepAlive.enabled = YES;
        return;
    }
    keepAlive.enabled = !keepAlive.enabled;
}

#pragma mark Tabs menu

- (void)nextTab:(id)sender {
    [self selectNeighborTab:1];
}
- (void)previousTab:(id)sender {
    [self selectNeighborTab:-1];
}
- (void)selectTabByNumber:(UICommand *)sender {
    [self selectTabAtIndex:[sender.propertyList unsignedIntegerValue]];
}

- (void)moveSelectedTabBy:(NSInteger)offset {
    NSInteger index = (NSInteger) [self.tabs indexOfObject:self.selectedSession];
    NSInteger target = index + offset;
    if (self.selectedSession == nil || target < 0 || target >= (NSInteger) self.tabs.count)
        return;
    [self.tabs exchangeObjectAtIndex:(NSUInteger) index withObjectAtIndex:(NSUInteger) target];
    [self tabsDidChange];
}
- (void)moveTabLeft:(id)sender {
    [self moveSelectedTabBy:-1];
}
- (void)moveTabRight:(id)sender {
    [self moveSelectedTabBy:1];
}

// Takes every tab out of this window without closing the shells, for another window to adopt.
- (NSArray<TerminalSession *> *)detachAllTabs {
    NSArray<TerminalSession *> *detached = [self.tabs copy];
    [self.tabs removeAllObjects];
    self.selectedSession = nil;
    return detached;
}

- (void)moveTabToNewWindow:(id)sender {
    TerminalSession *session = self.selectedSession;
    NSUInteger index = [self.tabs indexOfObject:session];
    if (index == NSNotFound || self.tabs.count < 2)
        return;
    [self.tabs removeObjectAtIndex:index];
    [self selectTabAtIndex:MIN(index, self.tabs.count - 1)];
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:SceneActivityType];
    [activity addUserInfoEntriesFromDictionary:@{SceneTerminalUUIDKey: session.uuid.UUIDString,
                                                 SceneTerminalUUIDsKey: @[session.uuid.UUIDString]}];
    [UIApplication.sharedApplication requestSceneSessionActivation:nil userActivity:activity options:nil errorHandler:^(NSError *error) {
        // No new window, so the tab comes back here rather than being lost.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session.state != TerminalSessionStateClosed && ![self.tabs containsObject:session]) {
                [self.tabs addObject:session];
                self.selectedSession = session;
            }
        });
    }];
}

- (void)mergeAllWindows:(id)sender {
    for (TerminalViewController *other in ConnectedTerminalViewControllers()) {
        if (other == self)
            continue;
        [self.tabs addObjectsFromArray:[other detachAllTabs]];
        [UIApplication.sharedApplication requestSceneSessionDestruction:other.sceneSession options:nil errorHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (other.tabs.count == 0)
                    [other startNewSession];
            });
        }];
    }
    [self tabsDidChange];
}

#pragma mark Tools menu

// Types a command line into the selected shell, as if at the keyboard. If something
// else owns the terminal (a job in the foreground, or a console being shown), offers
// to run it in a new tab instead of typing into whatever is running.
- (void)runInShell:(NSString *)command {
    TerminalSession *session = self.selectedSession;
    if (session.state == TerminalSessionStateRunning && session.shellIsForeground && self.terminal == session.terminal) {
        [session.terminal sendInput:[[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ is busy", session.displayTitle]
                                                                   message:command
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Run in New Tab" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self runInNewTab:command];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runInNewTab:(NSString *)command {
    TerminalSession *session = [self startNewSessionAtIndex:self.tabs.count];
    if (session != nil)
        [self typeCommand:command intoSession:session attempts:50];
}

// The new shell needs a moment to take the terminal; typing before that would be
// thrown away by login's terminal setup. Once the shell is there, a beat more lets
// it finish its own setup, so the text lands after its prompt.
- (void)typeCommand:(NSString *)command intoSession:(TerminalSession *)session attempts:(int)attempts {
    if (session.state != TerminalSessionStateRunning)
        return;
    if (session.shellIsForeground) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (session.state == TerminalSessionStateRunning)
                [session.terminal sendInput:[[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        });
        return;
    }
    if (attempts <= 0)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self typeCommand:command intoSession:session attempts:attempts - 1];
    });
}

- (void)mountFolder:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mount iOS Folder"
                                                                   message:@"A folder picker opens once the mount point is set. The mount is remembered across launches; use Unmount to forget it."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = @"/mnt/ios";
        textField.placeholder = @"Mount point";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *mount = [UIAlertAction actionWithTitle:@"Mount" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (path.length == 0)
            return;
        [self runInShell:[NSString stringWithFormat:@"mkdir -p %@ && mount -t ios . %@", ShellQuoted(path), ShellQuoted(path)]];
    }];
    [alert addAction:mount];
    alert.preferredAction = mount;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)unmountFolder:(UICommand *)sender {
    NSString *path = sender.propertyList;
    if ([path isKindOfClass:NSString.class])
        [self runInShell:[@"umount " stringByAppendingString:ShellQuoted(path)]];
}

- (void)copyCurrentDirectory:(id)sender {
    NSString *directory = self.selectedSession.currentDirectory;
    if (directory != nil)
        UIPasteboard.generalPasteboard.string = directory;
}

- (void)runSavedCommand:(UICommand *)sender {
    if ([sender.propertyList isKindOfClass:NSString.class])
        [self runInShell:sender.propertyList];
}

- (void)addSavedCommand:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Saved Command" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Command";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.font = [UIFont monospacedSystemFontOfSize:UIFont.systemFontSize weight:UIFontWeightRegular];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *add = [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *command = [weakAlert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (command.length == 0)
            return;
        [SavedCommand addWithName:name.length > 0 ? name : command command:command];
    }];
    [alert addAction:add];
    alert.preferredAction = add;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeSavedCommand:(UICommand *)sender {
    [SavedCommand removeAtIndex:[sender.propertyList unsignedIntegerValue]];
}

- (void)setTerminal:(Terminal *)terminal {
    _terminal = terminal;
    self.termView.terminal = self.terminal;
}

@end

@interface BarView : UIInputView
@property (weak) IBOutlet TerminalViewController *terminalViewController;
@property (nonatomic) IBInspectable BOOL allowsSelfSizing;
@end
@implementation BarView
@dynamic allowsSelfSizing;

- (void)layoutSubviews {
    [self.terminalViewController resizeBar];
}

@end
