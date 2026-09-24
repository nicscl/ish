//
//  ClipboardSettingsViewController.m
//  iSH
//

#import "ClipboardSettingsViewController.h"
#import "ClipboardStore.h"

typedef NS_ENUM(NSInteger, RowKind) {
    RowSwitch,
    RowChoice,   // a checkmark row among several
    RowMenu,     // a value picked from a pull-down
    RowButton,
    RowInfo,     // a label and a detail, not interactive
};

@interface SettingsRow : NSObject
@property RowKind kind;
@property NSString *title;
@property (nullable) NSString *detail;
@property BOOL destructive;
@property (copy, nullable) BOOL (^getter)(void);
@property (copy, nullable) void (^setter)(BOOL on);
@property (copy, nullable) void (^action)(UIView *source);
@property (copy, nullable) UIMenu *(^menu)(void);
@property (copy, nullable) NSString *(^value)(void);
@end
@implementation SettingsRow
@end

@interface SettingsSection : NSObject
@property NSString *title;
@property (nullable) NSString *footer;
@property NSArray<SettingsRow *> *rows;
@end
@implementation SettingsSection
@end

static SettingsRow *Switch(NSString *title, BOOL (^getter)(void), void (^setter)(BOOL)) {
    SettingsRow *row = [SettingsRow new];
    row.kind = RowSwitch;
    row.title = title;
    row.getter = getter;
    row.setter = setter;
    return row;
}

static SettingsRow *Choice(NSString *title, BOOL (^getter)(void), void (^pick)(void)) {
    SettingsRow *row = [SettingsRow new];
    row.kind = RowChoice;
    row.title = title;
    row.getter = getter;
    row.action = ^(UIView *source) { pick(); };
    return row;
}

static SettingsRow *Info(NSString *title, NSString *detail) {
    SettingsRow *row = [SettingsRow new];
    row.kind = RowInfo;
    row.title = title;
    row.detail = detail;
    return row;
}

static SettingsSection *Section(NSString *title, NSString *footer, NSArray<SettingsRow *> *rows) {
    SettingsSection *section = [SettingsSection new];
    section.title = title;
    section.footer = footer;
    section.rows = rows;
    return section;
}

@interface ClipboardSettingsViewController ()
@property NSArray<SettingsSection *> *sections;
@property (copy, nullable) void (^dismissHandler)(void);
@end

@implementation ClipboardSettingsViewController

+ (UIViewController *)navigationControllerWithDismissHandler:(void (^)(void))dismissHandler {
    ClipboardSettingsViewController *settings = [[ClipboardSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    settings.dismissHandler = dismissHandler;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigation;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Clipboard";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [self buildSections];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:ClipboardPauseDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:ClipboardStoreDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed && self.dismissHandler)
        self.dismissHandler();
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh {
    [self.tableView reloadData];
}

- (void)buildSections {
    ClipboardPreferences *prefs = ClipboardPreferences.shared;
    ClipboardStore *store = ClipboardStore.shared;
    __weak typeof(self) weakSelf = self;

    SettingsRow *cardSize = [SettingsRow new];
    cardSize.kind = RowMenu;
    cardSize.title = @"Card Size";
    NSArray<NSString *> *sizeNames = @[@"Compact", @"Regular", @"Large"];
    cardSize.value = ^{ return sizeNames[(NSUInteger) prefs.cardSize]; };
    cardSize.menu = ^UIMenu *{
        NSMutableArray *actions = [NSMutableArray new];
        [sizeNames enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
            UIAction *action = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(UIAction *a) {
                prefs.cardSize = (ClipCardSize) i;
                [weakSelf refresh];
            }];
            action.state = prefs.cardSize == (ClipCardSize) i ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }];
        return [UIMenu menuWithChildren:actions];
    };

    SettingsRow *retention = [SettingsRow new];
    retention.kind = RowMenu;
    retention.title = @"Keep History";
    retention.value = ^{ return ClipRetentionName(prefs.retention); };
    retention.menu = ^UIMenu *{
        NSMutableArray *actions = [NSMutableArray new];
        for (ClipRetention r = ClipRetentionDay; r <= ClipRetentionForever; r++) {
            NSString *title = r == ClipRetentionForever ? @"Forever" : [@"For a " stringByAppendingString:ClipRetentionName(r)];
            UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *a) {
                prefs.retention = r;
                [weakSelf refresh];
            }];
            action.state = prefs.retention == r ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        return [UIMenu menuWithChildren:actions];
    };

    SettingsRow *pause = [SettingsRow new];
    pause.kind = RowButton;
    pause.value = ^NSString *{
        if (!store.paused)
            return nil;
        if (store.pausedUntil == nil)
            return @"Paused";
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        return [@"Paused until " stringByAppendingString:[formatter stringFromDate:store.pausedUntil]];
    };
    pause.action = ^(UIView *source) {
        if (store.paused)
            [store resume];
        else
            [store pauseFor:0];
    };

    SettingsRow *erase = [SettingsRow new];
    erase.kind = RowButton;
    erase.title = @"Erase History…";
    erase.destructive = YES;
    erase.action = ^(UIView *source) { [weakSelf confirmErase]; };

    NSArray<NSArray<NSString *> *> *shortcuts = @[
        @[@"Show or Hide Clipboard", @"⇧⌘V"], @[@"Paste Stack", @"⇧⌘C"],
        @[@"Paste", @"↩"], @[@"Paste as Plain Text", @"⇧↩"],
        @[@"Quick Paste 1–9", @"⌘1 – ⌘9"], @[@"Quick Paste as Plain Text", @"⇧⌘1 – ⇧⌘9"],
        @[@"Select Next / Previous", @"→ / ←"], @[@"Extend Selection", @"⇧→ / ⇧←"],
        @[@"First / Last Item", @"⌘↑ / ⌘↓"], @[@"Select All", @"⌘A"],
        @[@"Copy", @"⌘C"], @[@"Preview", @"Space"], @[@"Open Link", @"⌘O"],
        @[@"Rename", @"⌘R"], @[@"Edit", @"⌘E"], @[@"New Text Item", @"⌘N"],
        @[@"Delete", @"⌫"], @[@"Undo / Redo", @"⌘Z / ⇧⌘Z"],
        @[@"Search", @"⌘F"], @[@"Show All Filters", @"⌘F in search"], @[@"Search Field / Results", @"Tab"],
        @[@"Show Item in Its List", @"⌘G"],
        @[@"New Pinboard", @"⇧⌘N"], @[@"Next / Previous Pinboard", @"⌘→ / ⌘←"],
        @[@"Pause or Resume Capture", @"⌘T"], @[@"Close", @"Esc"],
    ];
    NSMutableArray<SettingsRow *> *shortcutRows = [NSMutableArray new];
    for (NSArray<NSString *> *pair in shortcuts)
        [shortcutRows addObject:Info(pair[0], pair[1])];

    self.sections = @[
        Section(@"Paste Items", @"To Terminal types the item at the prompt of the tab the clipboard was opened over. Images are always copied to the clipboard.", @[
            Choice(@"To Terminal", ^{ return (BOOL) !prefs.pasteToClipboardOnly; }, ^{ prefs.pasteToClipboardOnly = NO; }),
            Choice(@"To Clipboard", ^{ return prefs.pasteToClipboardOnly; }, ^{ prefs.pasteToClipboardOnly = YES; }),
            Switch(@"Always Paste as Plain Text", ^{ return prefs.alwaysPlainText; }, ^(BOOL on) { prefs.alwaysPlainText = on; }),
        ]),
        Section(@"Capture", @"iOS only lets iSH read what other apps copied while iSH is in front, so those copies are collected when you switch back. To skip the permission prompt, set Paste from Other Apps to Allow in Settings › Apps › iSH.", @[
            Switch(@"Collect from Other Apps", ^{ return prefs.collectFromOtherApps; }, ^(BOOL on) { prefs.collectFromOtherApps = on; }),
            pause,
        ]),
        Section(@"History", [NSString stringWithFormat:@"%lu items in history. Pinned items are kept until you delete them.", (unsigned long) store.historyCount], @[
            retention,
            erase,
        ]),
        Section(@"Privacy", nil, @[
            Switch(@"Ignore Confidential Content", ^{ return prefs.ignoreConfidential; }, ^(BOOL on) { prefs.ignoreConfidential = on; }),
            Switch(@"Ignore Transient Content", ^{ return prefs.ignoreTransient; }, ^(BOOL on) { prefs.ignoreTransient = on; }),
            Switch(@"Generate Link Previews", ^{ return prefs.linkPreviews; }, ^(BOOL on) { prefs.linkPreviews = on; }),
        ]),
        Section(@"Appearance", nil, @[
            cardSize,
            Switch(@"Sound Effects", ^{ return prefs.soundEffects; }, ^(BOOL on) { prefs.soundEffects = on; }),
        ]),
        Section(@"Keyboard Shortcuts", nil, shortcutRows),
    ];
}

- (void)confirmErase {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Erase History?"
                                                                   message:@"Everything in the clipboard history will be deleted. Pinned items stay."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Erase" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [ClipboardStore.shared eraseHistory];
        [self buildSections];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger) self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger) self.sections[(NSUInteger) section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[(NSUInteger) section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.sections[(NSUInteger) section].footer;
}

- (SettingsRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
    return self.sections[(NSUInteger) indexPath.section].rows[(NSUInteger) indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SettingsRow *row = [self rowAtIndexPath:indexPath];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    UIListContentConfiguration *config = [UIListContentConfiguration valueCellConfiguration];
    config.text = row.title;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    switch (row.kind) {
        case RowSwitch: {
            UISwitch *toggle = [UISwitch new];
            toggle.on = row.getter();
            void (^setter)(BOOL) = row.setter;
            [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
                setter(((UISwitch *) action.sender).on);
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case RowChoice:
            cell.accessoryType = row.getter() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        case RowMenu: {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:row.value() forState:UIControlStateNormal];
            button.menu = row.menu();
            button.showsMenuAsPrimaryAction = YES;
            if (@available(iOS 15, *))
                button.changesSelectionAsPrimaryAction = NO;
            [button sizeToFit];
            cell.accessoryView = button;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case RowButton: {
            NSString *title = row.title;
            if (row.value != nil) {
                NSString *value = row.value();
                title = value ? @"Resume Capture" : @"Pause Capture";
                config.secondaryText = value;
            }
            config.text = title;
            config.textProperties.color = row.destructive ? UIColor.systemRedColor : self.view.tintColor;
            break;
        }
        case RowInfo:
            config.secondaryText = row.detail;
            config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    cell.contentConfiguration = config;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SettingsRow *row = [self rowAtIndexPath:indexPath];
    if (row.action != nil) {
        row.action([tableView cellForRowAtIndexPath:indexPath]);
        [self refresh];
    }
}

@end
