//
//  MainMenu.m
//  iSH
//

#import "MainMenu.h"
#import "Theme.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "iOSFS.h"

static NSString *const kSavedCommands = @"Saved Commands";

#pragma mark - Building blocks

static NSString *ID(NSString *name) {
    return [@"dev.nicholas.ish.menu." stringByAppendingString:name];
}

static UIImage *Symbol(NSString *name) {
    return name == nil ? nil : [UIImage systemImageNamed:name];
}

static UIKeyCommand *Key(NSString *title, NSString *symbol, SEL action, NSString *input, UIKeyModifierFlags modifiers, id propertyList) {
    UIKeyCommand *command = [UIKeyCommand commandWithTitle:title
                                                     image:Symbol(symbol)
                                                    action:action
                                                     input:input
                                             modifierFlags:modifiers
                                              propertyList:propertyList];
    // Cmd+number and Cmd+Shift+bracket must not be taken by the system first.
    command.wantsPriorityOverSystemBehavior = YES;
    return command;
}

static UICommand *Cmd(NSString *title, NSString *symbol, SEL action, id propertyList) {
    return [UICommand commandWithTitle:title image:Symbol(symbol) action:action propertyList:propertyList];
}

// A separator-delimited group inside another menu.
static UIMenu *Group(NSString *name, NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:ID(name) options:UIMenuOptionsDisplayInline children:children];
}

static UIMenu *Submenu(NSString *title, NSString *symbol, NSString *name, NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:title image:Symbol(symbol) identifier:ID(name) options:0 children:children];
}

// A submenu whose contents are computed each time it opens.
static UIMenu *DynamicSubmenu(NSString *title, NSString *symbol, NSString *name, NSArray<UIMenuElement *> *(^provider)(void)) {
    UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(provider());
    }];
    return Submenu(title, symbol, name, @[deferred]);
}

static UIAction *Link(NSString *title, NSString *symbol, NSString *url) {
    return [UIAction actionWithTitle:title image:Symbol(symbol) identifier:nil handler:^(UIAction *action) {
        [UIApplication openURL:url];
    }];
}

static const UIKeyModifierFlags kCmd = UIKeyModifierCommand;
static const UIKeyModifierFlags kShiftCmd = UIKeyModifierCommand | UIKeyModifierShift;
static const UIKeyModifierFlags kAltCmd = UIKeyModifierCommand | UIKeyModifierAlternate;

#pragma mark - Menus

static UIMenu *ShellMenu(void) {
    return Submenu(@"Shell", @"terminal", @"shell", @[
        Group(@"shell.new", @[
            Key(@"New Tab", @"plus", @selector(newTab:), @"t", kCmd, nil),
            Key(@"New Window", @"macwindow.badge.plus", @selector(newWindow:), @"n", kCmd, nil),
            Cmd(@"Duplicate Tab", @"plus.square.on.square", @selector(duplicateTab:), nil),
        ]),
        Group(@"shell.manage", @[
            Key(@"Rename Tab…", @"pencil", @selector(renameCurrentTab:), @"i", kCmd, nil),
            Cmd(@"Restart Shell", @"arrow.clockwise", @selector(restartShell:), nil),
            Cmd(@"Reset Terminal", @"arrow.counterclockwise", @selector(resetTerminal:), nil),
        ]),
        Group(@"shell.send", @[
            Submenu(@"Send", @"paperplane", @"send", @[
                Cmd(@"Interrupt (Ctrl+C)", nil, @selector(sendInterrupt:), nil),
                Cmd(@"End of File (Ctrl+D)", nil, @selector(sendEndOfFile:), nil),
                Cmd(@"Suspend (Ctrl+Z)", nil, @selector(sendSuspend:), nil),
                Cmd(@"Kill Foreground Job", nil, @selector(killForegroundJob:), nil),
            ]),
            Key(@"Export Scrollback…", @"square.and.arrow.up", @selector(exportScrollback:), @"s", kShiftCmd, nil),
        ]),
        Group(@"shell.close", @[
            Key(@"Close Tab", @"xmark", @selector(closeCurrentTab:), @"w", kCmd, nil),
            Key(@"Close Other Tabs", nil, @selector(closeOtherTabs:), @"w", kAltCmd, nil),
            Key(@"Close Window", nil, @selector(closeWindow:), @"w", kShiftCmd, nil),
        ]),
    ]);
}

// Goes after Copy/Paste in the Edit menu.
static UIMenu *EditExtras(void) {
    return Group(@"edit.clear", @[
        Key(@"Clear Screen", @"eraser", @selector(clearScreen:), @"k", kCmd, nil),
        Key(@"Clear Scrollback", nil, @selector(clearScrollback:), @"k", kShiftCmd, nil),
    ]);
}

static NSArray<UIMenuElement *> *ThemeItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];
    for (Theme *theme in Theme.defaultThemes)
        [items addObject:Cmd(theme.name, nil, @selector(selectTheme:), theme.name)];
    NSMutableArray<UIMenuElement *> *user = [NSMutableArray new];
    for (Theme *theme in Theme.userThemes)
        [user addObject:Cmd(theme.name, nil, @selector(selectTheme:), theme.name)];
    if (user.count > 0)
        [items addObject:Group(@"theme.user", user)];
    return items;
}

static UIMenu *ViewMenu(void) {
    NSMutableArray<UIMenuElement *> *consoles = [NSMutableArray new];
    for (int i = 1; i <= 6; i++) {
        [consoles addObject:Key([NSString stringWithFormat:@"Console %d", i], nil, @selector(switchTerminal:),
                                [NSString stringWithFormat:@"%d", i], kShiftCmd | UIKeyModifierAlternate, @(i))];
    }
    [consoles addObject:Key(@"Shell", nil, @selector(switchTerminal:), @"7", kShiftCmd | UIKeyModifierAlternate, @7)];
    return Submenu(@"View", @"textformat.size", @"view", @[
        Group(@"view.font", @[
            Key(@"Bigger", @"plus.magnifyingglass", @selector(increaseFontSize:), @"+", kCmd, nil),
            Key(@"Smaller", @"minus.magnifyingglass", @selector(decreaseFontSize:), @"-", kCmd, nil),
            Key(@"Actual Size", nil, @selector(resetFontSize:), @"0", kCmd, nil),
        ]),
        Group(@"view.appearance", @[
            DynamicSubmenu(@"Theme", @"paintpalette", @"theme", ^{ return ThemeItems(); }),
            Submenu(@"Appearance", @"circle.lefthalf.filled", @"appearance", @[
                Cmd(@"Match System", nil, @selector(selectColorScheme:), @(ColorSchemeMatchSystem)),
                Cmd(@"Light", nil, @selector(selectColorScheme:), @(ColorSchemeAlwaysLight)),
                Cmd(@"Dark", nil, @selector(selectColorScheme:), @(ColorSchemeAlwaysDark)),
            ]),
        ]),
        Group(@"view.toggles", @[
            Cmd(@"Extra Keys with Hardware Keyboard", @"keyboard", @selector(toggleExtraKeys:), nil),
            Cmd(@"Hide Status Bar", nil, @selector(toggleStatusBar:), nil),
        ]),
        Group(@"view.console", @[
            Submenu(@"Console", @"display", @"console", consoles),
        ]),
    ]);
}

static UIMenu *TabsMenu(void) {
    NSMutableArray<UIMenuElement *> *tabs = [NSMutableArray new];
    // Titles and visibility are filled in by validateCommand: from the tabs that exist.
    for (int i = 1; i <= 9; i++) {
        [tabs addObject:Key([NSString stringWithFormat:@"Tab %d", i], nil, @selector(selectTabByNumber:),
                            [NSString stringWithFormat:@"%d", i], kCmd, @(i - 1))];
    }
    return Submenu(@"Tabs", @"rectangle.stack", @"tabs", @[
        Group(@"tabs.cycle", @[
            Key(@"Next Tab", @"arrow.right", @selector(nextTab:), @"]", kShiftCmd, nil),
            Key(@"Previous Tab", @"arrow.left", @selector(previousTab:), @"[", kShiftCmd, nil),
        ]),
        Group(@"tabs.move", @[
            Key(@"Move Tab Left", nil, @selector(moveTabLeft:), UIKeyInputLeftArrow, kShiftCmd, nil),
            Key(@"Move Tab Right", nil, @selector(moveTabRight:), UIKeyInputRightArrow, kShiftCmd, nil),
            Cmd(@"Move Tab to New Window", @"macwindow.on.rectangle", @selector(moveTabToNewWindow:), nil),
            Cmd(@"Merge All Windows", @"rectangle.on.rectangle", @selector(mergeAllWindows:), nil),
        ]),
        Group(@"tabs.list", tabs),
    ]);
}

static NSArray<UIMenuElement *> *UnmountItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];
    for (NSString *path in iosfs_mount_points())
        [items addObject:Cmd(path, nil, @selector(unmountFolder:), path)];
    if (items.count == 0) {
        UICommand *none = Cmd(@"No Mounted Folders", nil, @selector(unmountFolder:), nil);
        none.attributes = UIMenuElementAttributesDisabled;
        [items addObject:none];
    }
    return items;
}

static NSArray<UIMenuElement *> *SavedCommandItems(void) {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];
    NSMutableArray<UIMenuElement *> *remove = [NSMutableArray new];
    [SavedCommand.all enumerateObjectsUsingBlock:^(SavedCommand *saved, NSUInteger i, BOOL *stop) {
        [items addObject:Cmd(saved.name, nil, @selector(runSavedCommand:), saved.command)];
        [remove addObject:Cmd(saved.name, nil, @selector(removeSavedCommand:), @(i))];
    }];
    NSMutableArray<UIMenuElement *> *manage = [NSMutableArray new];
    [manage addObject:Cmd(@"Add Saved Command…", @"plus", @selector(addSavedCommand:), nil)];
    if (remove.count > 0)
        [manage addObject:Submenu(@"Remove", @"minus", @"savedcommands.remove", remove)];
    [items addObject:Group(@"savedcommands.manage", manage)];
    return items;
}

static UIMenu *ToolsMenu(void) {
    return Submenu(@"Tools", @"wrench.and.screwdriver", @"tools", @[
        Group(@"tools.mount", @[
            Cmd(@"Mount iOS Folder…", @"folder.badge.plus", @selector(mountFolder:), nil),
            DynamicSubmenu(@"Unmount", @"eject", @"unmount", ^{ return UnmountItems(); }),
        ]),
        Group(@"tools.directory", @[
            Cmd(@"Copy Working Directory", @"doc.on.doc", @selector(copyCurrentDirectory:), nil),
        ]),
        Group(@"tools.background", @[
            Cmd(@"Keep Running in Background", @"location", @selector(toggleKeepAlive:), nil),
        ]),
        Group(@"tools.saved", @[
            DynamicSubmenu(@"Saved Commands", @"bolt", @"savedcommands", ^{ return SavedCommandItems(); }),
        ]),
    ]);
}

static NSArray<UIMenuElement *> *HelpItems(void) {
    return @[
        Link(@"iSH Wiki", @"book", @"https://github.com/ish-app/ish/wiki"),
        Link(@"Fork on GitHub", @"chevron.left.forwardslash.chevron.right", @"https://github.com/nicscl/ish"),
        Link(@"Report an Issue", @"exclamationmark.bubble", @"https://github.com/nicscl/ish/issues/new"),
    ];
}

static UICommand *SettingsCommand(void) {
    return Key(@"Settings…", @"gear", @selector(showAbout:), @",", kCmd, nil);
}

#pragma mark - MainMenu

@implementation MainMenu

+ (void)buildWithBuilder:(id<UIMenuBuilder>)builder {
    // Stock menus that make no sense for a terminal. Their key equivalents would
    // otherwise swallow the keys (Cmd+I for italic, for instance) before any
    // command of ours sees them.
    for (UIMenuIdentifier identifier in @[UIMenuFormat, UIMenuUndoRedo, UIMenuSpelling, UIMenuSubstitutions,
                                          UIMenuTransformations, UIMenuSpeech, UIMenuLookup, UIMenuLearn,
                                          UIMenuFind, UIMenuFile, UIMenuPreferences]) {
        if ([builder menuForIdentifier:identifier] != nil)
            [builder removeMenuForIdentifier:identifier];
    }
    if (@available(iOS 17, *)) {
        if ([builder menuForIdentifier:UIMenuAutoFill] != nil)
            [builder removeMenuForIdentifier:UIMenuAutoFill];
    }

    UIMenu *settings = Group(@"settings", @[SettingsCommand()]);
    if ([builder menuForIdentifier:UIMenuAbout] != nil)
        [builder insertSiblingMenu:settings afterMenuForIdentifier:UIMenuAbout];
    else
        [builder insertChildMenu:settings atStartOfMenuForIdentifier:UIMenuApplication];

    [builder insertSiblingMenu:ShellMenu() afterMenuForIdentifier:UIMenuApplication];
    if ([builder menuForIdentifier:UIMenuStandardEdit] != nil)
        [builder insertSiblingMenu:EditExtras() afterMenuForIdentifier:UIMenuStandardEdit];
    else
        [builder insertChildMenu:EditExtras() atEndOfMenuForIdentifier:UIMenuEdit];

    UIMenu *view = ViewMenu();
    if ([builder menuForIdentifier:UIMenuView] != nil) {
        [builder insertChildMenu:Group(@"view.ours", view.children) atStartOfMenuForIdentifier:UIMenuView];
    } else {
        [builder insertSiblingMenu:view afterMenuForIdentifier:UIMenuEdit];
    }
    [builder insertSiblingMenu:TabsMenu() afterMenuForIdentifier:UIMenuView];
    [builder insertSiblingMenu:ToolsMenu() afterMenuForIdentifier:ID(@"tabs")];

    UIMenu *help = Group(@"help.links", HelpItems());
    if ([builder menuForIdentifier:UIMenuHelp] != nil)
        [builder insertChildMenu:help atStartOfMenuForIdentifier:UIMenuHelp];
    else
        [builder insertSiblingMenu:Submenu(@"Help", nil, @"help", help.children) afterMenuForIdentifier:UIMenuWindow];
}

+ (UIMenu *)commandsMenu {
    return [UIMenu menuWithTitle:@"" image:nil identifier:ID(@"commands") options:0 children:@[
        Group(@"commands.quick", @[
            Key(@"New Tab", @"plus", @selector(newTab:), @"t", kCmd, nil),
            SettingsCommand(),
        ]),
        ShellMenu(),
        Submenu(@"Edit", @"doc.on.clipboard", @"edit", @[
            Cmd(@"Paste", @"doc.on.clipboard", @selector(paste:), nil),
            EditExtras(),
        ]),
        ViewMenu(),
        TabsMenu(),
        ToolsMenu(),
        Submenu(@"Help", @"questionmark.circle", @"help", HelpItems()),
    ]];
}

@end

#pragma mark - SavedCommand

@interface SavedCommand ()
@property NSString *name;
@property NSString *command;
@end

@implementation SavedCommand

+ (NSArray<SavedCommand *> *)all {
    NSMutableArray<SavedCommand *> *result = [NSMutableArray new];
    for (id entry in [NSUserDefaults.standardUserDefaults arrayForKey:kSavedCommands]) {
        if (![entry isKindOfClass:NSDictionary.class])
            continue;
        NSString *name = entry[@"name"], *command = entry[@"command"];
        if (![name isKindOfClass:NSString.class] || ![command isKindOfClass:NSString.class])
            continue;
        SavedCommand *saved = [SavedCommand new];
        saved.name = name;
        saved.command = command;
        [result addObject:saved];
    }
    return result;
}

+ (void)save:(NSArray<SavedCommand *> *)commands {
    NSMutableArray *entries = [NSMutableArray new];
    for (SavedCommand *saved in commands)
        [entries addObject:@{@"name": saved.name, @"command": saved.command}];
    [NSUserDefaults.standardUserDefaults setObject:entries forKey:kSavedCommands];
}

+ (void)addWithName:(NSString *)name command:(NSString *)command {
    SavedCommand *saved = [SavedCommand new];
    saved.name = name;
    saved.command = command;
    [self save:[self.all arrayByAddingObject:saved]];
}

+ (void)removeAtIndex:(NSUInteger)index {
    NSMutableArray<SavedCommand *> *commands = [self.all mutableCopy];
    if (index < commands.count)
        [commands removeObjectAtIndex:index];
    [self save:commands];
}

@end
