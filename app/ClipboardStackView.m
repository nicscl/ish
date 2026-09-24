//
//  ClipboardStackView.m
//  iSH
//

#import "ClipboardStackView.h"
#import "ClipboardStore.h"
#import "ClipboardUI.h"

static const CGFloat kRowHeight = 44;
static const NSUInteger kMaxVisibleRows = 6;

@interface ClipboardStackView () <UITableViewDataSource, UITableViewDelegate>
@property UIVisualEffectView *glass;
@property UILabel *titleLabel;
@property UIButton *reverseButton;
@property UITableView *table;
@property UILabel *hintLabel;
@property NSLayoutConstraint *tableHeight;
@property NSArray<ClipItem *> *items;
@end

@implementation ClipboardStackView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.accessibilityIdentifier = @"paste stack";
        self.glass = ClipGlassView(22);
        self.glass.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.glass];
        UIView *content = self.glass.contentView;

        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.stack.3d.up.fill"]];
        icon.tintColor = self.tintColor;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:icon];

        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:self.titleLabel];

        self.reverseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.reverseButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] forState:UIControlStateNormal];
        self.reverseButton.accessibilityLabel = @"Reverse Order";
        [self.reverseButton addTarget:self action:@selector(reverse) forControlEvents:UIControlEventPrimaryActionTriggered];
        self.reverseButton.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:self.reverseButton];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeClose];
        close.accessibilityLabel = @"Close Paste Stack";
        [close addTarget:self action:@selector(close) forControlEvents:UIControlEventPrimaryActionTriggered];
        close.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:close];

        self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        self.table.backgroundColor = UIColor.clearColor;
        self.table.rowHeight = kRowHeight;
        self.table.dataSource = self;
        self.table.delegate = self;
        self.table.separatorInset = UIEdgeInsetsMake(0, 52, 0, 0);
        self.table.translatesAutoresizingMaskIntoConstraints = NO;
        [self.table registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
        [content addSubview:self.table];

        self.hintLabel = [UILabel new];
        self.hintLabel.font = [UIFont systemFontOfSize:12];
        self.hintLabel.textColor = UIColor.secondaryLabelColor;
        self.hintLabel.numberOfLines = 0;
        self.hintLabel.textAlignment = NSTextAlignmentCenter;
        self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:self.hintLabel];

        self.tableHeight = [self.table.heightAnchor constraintEqualToConstant:0];
        [NSLayoutConstraint activateConstraints:@[
            [self.glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.glass.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.widthAnchor constraintEqualToConstant:300],

            [icon.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
            [icon.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:24],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
            [self.reverseButton.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-12],
            [self.reverseButton.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
            [close.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [close.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],

            [self.table.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [self.table.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [self.table.topAnchor constraintEqualToAnchor:content.topAnchor constant:48],
            self.tableHeight,
            [self.hintLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
            [self.hintLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
            [self.hintLabel.topAnchor constraintEqualToAnchor:self.table.bottomAnchor constant:8],
            [self.hintLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:ClipboardStackDidChangeNotification object:nil];
        [self reload];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
    ClipboardStore *store = ClipboardStore.shared;
    self.items = store.stackItems;
    NSUInteger count = self.items.count;
    self.titleLabel.text = count == 0 ? @"Paste Stack" : [NSString stringWithFormat:@"Paste Stack · %lu", (unsigned long) count];
    self.reverseButton.enabled = count > 1;
    self.hintLabel.text = count == 0 ? @"Copy things to stack them up, then paste them one after another with ⌘V."
                                     : (store.stackReversed ? @"⌘V pastes from the bottom up." : @"⌘V pastes from the top down.");
    self.tableHeight.constant = MIN(count, kMaxVisibleRows) * kRowHeight;
    self.table.scrollEnabled = count > kMaxVisibleRows;
    [self.table reloadData];
}

- (void)reverse {
    ClipboardStore.shared.stackReversed = !ClipboardStore.shared.stackReversed;
}

- (void)close {
    if (self.closeHandler)
        self.closeHandler();
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger) self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    ClipItem *item = self.items[(NSUInteger) indexPath.row];
    UIListContentConfiguration *config = [UIListContentConfiguration cellConfiguration];
    config.text = item.displayTitle;
    config.textProperties.numberOfLines = 1;
    config.textProperties.font = indexPath.row == 0 ? [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:14];
    UIImage *thumbnail = item.thumbnail;
    config.image = thumbnail ?: [UIImage systemImageNamed:ClipKindSymbol(item.kind)];
    config.imageProperties.maximumSize = CGSizeMake(28, 28);
    config.imageProperties.cornerRadius = 5;
    config.imageProperties.tintColor = indexPath.row == 0 ? self.tintColor : UIColor.secondaryLabelColor;
    cell.contentConfiguration = config;
    cell.backgroundColor = indexPath.row == 0 ? [self.tintColor colorWithAlphaComponent:0.12] : UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityLabel = indexPath.row == 0 ? [@"Next: " stringByAppendingString:item.displayTitle] : item.displayTitle;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [ClipboardStore.shared removeStackItemAtIndex:(NSUInteger) indexPath.row];
            completion(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSUInteger row = (NSUInteger) indexPath.row;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *remove = [UIAction actionWithTitle:@"Remove from Stack" image:[UIImage systemImageNamed:@"minus.circle"] identifier:nil handler:^(UIAction *action) {
            [ClipboardStore.shared removeStackItemAtIndex:row];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[remove]];
    }];
}

@end
