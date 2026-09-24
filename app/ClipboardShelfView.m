//
//  ClipboardShelfView.m
//  iSH
//

#import <AudioToolbox/AudioToolbox.h>
#import "ClipboardShelfView.h"
#import "ClipboardItemViewController.h"
#import "ClipboardUI.h"
#import "UIApplication+OpenURL.h"

static const CGFloat kHeaderHeight = 52;
static const CGFloat kCardSpacing = 14;
static const CGFloat kCardInset = 18;
static NSString *const kCardReuse = @"card";
static NSString *const kTabReuse = @"tab";

// What a filter token stands for.
typedef NS_ENUM(NSInteger, FilterType) {
    FilterKind,
    FilterSource,
    FilterDate,
    FilterPinboard,
};



@interface ClipFilter : NSObject
@property FilterType type;
@property id value; // NSNumber, or a pinboard ID (@"" for the history)
@property NSString *title;
@property NSString *symbol;
@property (nullable) UIColor *color;
@end
@implementation ClipFilter
- (BOOL)isEqual:(ClipFilter *)other {
    return [other isKindOfClass:ClipFilter.class] && other.type == self.type && [other.value isEqual:self.value];
}
- (NSUInteger)hash {
    return [self.value hash] ^ (NSUInteger) self.type;
}
@end

// Lets drags from a card start without the strip scrolling instead.
@interface ClipCollectionView : UICollectionView
@end
@implementation ClipCollectionView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}
@end

@interface ClipboardShelfView () <UICollectionViewDelegateFlowLayout, UICollectionViewDataSource,
                                  UICollectionViewDragDelegate, UICollectionViewDropDelegate,
                                  UISearchTextFieldDelegate, UITextFieldDelegate, UIKeyInput>
@property UIVisualEffectView *glass;
@property UIView *header;
@property UIButton *searchButton;
@property UICollectionView *tabs;
@property UISearchTextField *searchField;
@property UIButton *filterButton;
@property UIButton *pausedButton;
@property UIButton *addButton;
@property UIButton *moreButton;
@property UICollectionView *cards;
@property UICollectionViewDiffableDataSource<NSNumber *, NSString *> *dataSource;
@property UILabel *emptyLabel;

// nil: the history.
@property (nullable) ClipPinboard *pinboard;
@property BOOL searching;
@property ClipQuery *query;
@property NSArray<ClipItem *> *displayed;
@property NSDictionary<NSString *, ClipItem *> *itemsByID;
@property NSMutableOrderedSet<NSString *> *selection;
@property (nullable) NSString *anchor;
@property BOOL selectMode;
@property BOOL commandHeld;
@property (nonatomic, nullable) NSIndexPath *dropTargetTab;
@end

@implementation ClipboardShelfView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _query = [ClipQuery new];
        _selection = [NSMutableOrderedSet new];
        _displayed = @[];
        _itemsByID = @{};
        [self buildViews];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(storeDidChange:) name:ClipboardStoreDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(pauseDidChange:) name:ClipboardPauseDidChangeNotification object:nil];
        self.accessibilityIdentifier = @"clipboard shelf";
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark Views

static UIButton *HeaderButton(NSString *symbol, NSString *label) {
    UIButton *button;
    if (@available(iOS 26, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration glassButtonConfiguration];
        config.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]];
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    } else {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]]
                forState:UIControlStateNormal];
        button.tintColor = UIColor.labelColor;
    }
    button.accessibilityLabel = label;
    button.pointerInteractionEnabled = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:34],
        [button.heightAnchor constraintEqualToConstant:34],
    ]];
    return button;
}

- (void)buildViews {
    self.glass = ClipGlassView(30);
    self.glass.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.glass];
    UIView *content = self.glass.contentView;

    self.header = [UIView new];
    self.header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.header];

    self.searchButton = HeaderButton(@"magnifyingglass", @"Search");
    [self.searchButton addTarget:self action:@selector(searchButtonTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    self.searchButton.accessibilityIdentifier = @"clipboard search";
    [self.header addSubview:self.searchButton];

    UICollectionViewFlowLayout *tabLayout = [UICollectionViewFlowLayout new];
    tabLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    tabLayout.minimumInteritemSpacing = 4;
    tabLayout.minimumLineSpacing = 4;
    self.tabs = [[ClipCollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:tabLayout];
    self.tabs.backgroundColor = UIColor.clearColor;
    self.tabs.showsHorizontalScrollIndicator = NO;
    self.tabs.dataSource = self;
    self.tabs.delegate = self;
    self.tabs.dragDelegate = self;
    self.tabs.dropDelegate = self;
    self.tabs.dragInteractionEnabled = YES;
    self.tabs.allowsFocus = NO;
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabs registerClass:ClipTabCell.class forCellWithReuseIdentifier:kTabReuse];
    [self.header addSubview:self.tabs];

    self.searchField = [UISearchTextField new];
    self.searchField.placeholder = @"Search clipboard";
    self.searchField.delegate = self;
    self.searchField.returnKeyType = UIReturnKeyDone;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchField.allowsDeletingTokens = YES;
    self.searchField.hidden = YES;
    self.searchField.accessibilityIdentifier = @"clipboard search field";
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.searchField addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
    [self.header addSubview:self.searchField];

    self.filterButton = HeaderButton(@"line.3.horizontal.decrease", @"Filters");
    self.filterButton.showsMenuAsPrimaryAction = YES;
    self.filterButton.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.filterButton.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(weakSelf ? [weakSelf filterMenuElements] : @[]);
    }]]];
    [self.header addSubview:self.filterButton];

    UIButtonConfiguration *pausedConfig = [UIButtonConfiguration tintedButtonConfiguration];
    pausedConfig.title = @"Paused";
    pausedConfig.image = [UIImage systemImageNamed:@"pause.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10]];
    pausedConfig.imagePadding = 4;
    pausedConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    pausedConfig.baseForegroundColor = UIColor.systemOrangeColor;
    pausedConfig.baseBackgroundColor = UIColor.systemOrangeColor;
    pausedConfig.contentInsets = NSDirectionalEdgeInsetsMake(4, 10, 4, 10);
    pausedConfig.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        return result;
    };
    self.pausedButton = [UIButton buttonWithConfiguration:pausedConfig primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
        [ClipboardStore.shared resume];
    }]];
    self.pausedButton.accessibilityLabel = @"Capture paused. Resume";
    self.pausedButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.header addSubview:self.pausedButton];

    self.addButton = HeaderButton(@"plus", @"New Pinboard");
    [self.addButton addTarget:self action:@selector(promptForNewPinboard) forControlEvents:UIControlEventPrimaryActionTriggered];
    self.addButton.accessibilityIdentifier = @"new pinboard";
    [self.header addSubview:self.addButton];

    self.moreButton = HeaderButton(@"ellipsis", @"More");
    self.moreButton.showsMenuAsPrimaryAction = YES;
    self.moreButton.accessibilityIdentifier = @"clipboard more";
    self.moreButton.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(weakSelf ? [weakSelf moreMenuElements] : @[]);
    }]]];
    [self.header addSubview:self.moreButton];

    UICollectionViewFlowLayout *cardLayout = [UICollectionViewFlowLayout new];
    cardLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    cardLayout.minimumLineSpacing = kCardSpacing;
    cardLayout.sectionInset = UIEdgeInsetsMake(0, kCardInset, 0, kCardInset);
    self.cards = [[ClipCollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:cardLayout];
    self.cards.backgroundColor = UIColor.clearColor;
    self.cards.showsHorizontalScrollIndicator = NO;
    self.cards.clipsToBounds = NO;
    self.cards.delegate = self;
    self.cards.dragDelegate = self;
    self.cards.dropDelegate = self;
    self.cards.dragInteractionEnabled = YES;
    self.cards.allowsSelection = NO;
    self.cards.allowsFocus = NO;
    self.cards.accessibilityIdentifier = @"clipboard items";
    self.cards.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cards registerClass:ClipCardCell.class forCellWithReuseIdentifier:kCardReuse];
    [content addSubview:self.cards];
    self.dataSource = [[UICollectionViewDiffableDataSource alloc] initWithCollectionView:self.cards
        cellProvider:^UICollectionViewCell *(UICollectionView *collectionView, NSIndexPath *indexPath, NSString *identifier) {
            ClipCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCardReuse forIndexPath:indexPath];
            [weakSelf configureCell:cell identifier:identifier];
            return cell;
        }];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardsTapped:)];
    [self.cards addGestureRecognizer:tap];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.header.topAnchor constraintEqualToAnchor:content.topAnchor constant:4],
        [self.header.heightAnchor constraintEqualToConstant:kHeaderHeight],

        [self.searchButton.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor],
        [self.searchButton.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.tabs.leadingAnchor constraintEqualToAnchor:self.searchButton.trailingAnchor constant:8],
        [self.tabs.trailingAnchor constraintEqualToAnchor:self.pausedButton.leadingAnchor constant:-8],
        [self.tabs.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.tabs.heightAnchor constraintEqualToConstant:34],
        [self.searchField.leadingAnchor constraintEqualToAnchor:self.searchButton.trailingAnchor constant:8],
        [self.searchField.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-8],
        [self.searchField.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.searchField.heightAnchor constraintEqualToConstant:36],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.pausedButton.leadingAnchor constant:-8],
        [self.filterButton.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.pausedButton.trailingAnchor constraintEqualToAnchor:self.addButton.leadingAnchor constant:-8],
        [self.pausedButton.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.addButton.trailingAnchor constraintEqualToAnchor:self.moreButton.leadingAnchor constant:-8],
        [self.addButton.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],
        [self.moreButton.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor],
        [self.moreButton.centerYAnchor constraintEqualToAnchor:self.header.centerYAnchor],

        [self.cards.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.cards.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.cards.topAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:4],
        [self.cards.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.cards.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.cards.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.cards.widthAnchor constant:-40],
    ]];
    [self pauseDidChange:nil];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, self.preferredHeight);
}

- (CGFloat)preferredHeight {
    return 4 + kHeaderHeight + 4 + [self cardSide] + 14 + 8;
}

- (CGFloat)cardSide {
    return ClipCardSide(ClipboardPreferences.shared.cardSize, self.traitCollection);
}

#pragma mark Data

- (void)prepareToShow {
    self.selectMode = NO;
    [self reloadAnimated:NO];
    [self.tabs reloadData];
    [self selectOnly:self.displayed.firstObject scroll:YES];
    [self.cards setContentOffset:CGPointZero animated:NO];
}

- (void)storeDidChange:(NSNotification *)notif {
    // A pinboard shown here may be gone.
    if (self.pinboard != nil && [ClipboardStore.shared pinboardWithID:self.pinboard.identifier] == nil)
        self.pinboard = nil;
    [self.tabs reloadData];
    NSSet<NSString *> *updated = notif.userInfo[ClipboardUpdatedItemsKey];
    [self reloadAnimated:self.window != nil && !self.hidden updated:updated];
    [self.cards.collectionViewLayout invalidateLayout];
    [self invalidateIntrinsicContentSize];
}

- (void)pauseDidChange:(NSNotification *)notif {
    self.pausedButton.hidden = !ClipboardStore.shared.paused;
    NSDate *until = ClipboardStore.shared.pausedUntil;
    if (until != nil) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        self.pausedButton.accessibilityLabel = [NSString stringWithFormat:@"Capture paused until %@. Resume", [formatter stringFromDate:until]];
    }
}

- (void)reloadAnimated:(BOOL)animated {
    [self reloadAnimated:animated updated:nil];
}

- (void)reloadAnimated:(BOOL)animated updated:(NSSet<NSString *> *)updated {
    ClipboardStore *store = ClipboardStore.shared;
    if (self.searching) {
        self.displayed = [store itemsMatchingQuery:self.query];
    } else {
        self.displayed = [store itemsInPinboard:self.pinboard];
    }
    NSMutableDictionary<NSString *, ClipItem *> *byID = [NSMutableDictionary new];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (ClipItem *item in self.displayed) {
        byID[item.identifier] = item;
        [ids addObject:item.identifier];
    }
    self.itemsByID = byID;
    // Drop selected items that went away.
    NSMutableOrderedSet<NSString *> *kept = [NSMutableOrderedSet new];
    for (NSString *identifier in self.selection) {
        if (byID[identifier] != nil)
            [kept addObject:identifier];
    }
    BOOL lostSelection = self.selection.count > 0 && kept.count == 0;
    self.selection = kept;

    NSDiffableDataSourceSnapshot<NSNumber *, NSString *> *snapshot = [NSDiffableDataSourceSnapshot new];
    [snapshot appendSectionsWithIdentifiers:@[@0]];
    [snapshot appendItemsWithIdentifiers:ids];
    NSMutableArray<NSString *> *reconfigure = [NSMutableArray new];
    for (NSString *identifier in updated) {
        if (byID[identifier] != nil)
            [reconfigure addObject:identifier];
    }
    if (reconfigure.count > 0)
        [snapshot reconfigureItemsWithIdentifiers:reconfigure];
    [self.dataSource applySnapshot:snapshot animatingDifferences:animated];
    // Relative times and pinboard dots change without the item changing.
    for (NSIndexPath *indexPath in self.cards.indexPathsForVisibleItems) {
        ClipCardCell *cell = (ClipCardCell *) [self.cards cellForItemAtIndexPath:indexPath];
        NSString *identifier = [self.dataSource itemIdentifierForIndexPath:indexPath];
        if (cell != nil && identifier != nil)
            [self configureCell:cell identifier:identifier];
    }
    if (lostSelection || (self.selection.count == 0 && !self.selectMode))
        [self selectOnly:self.displayed.firstObject scroll:NO];

    if (self.displayed.count > 0) {
        self.emptyLabel.hidden = YES;
    } else {
        self.emptyLabel.hidden = NO;
        if (self.searching)
            self.emptyLabel.text = @"No Results";
        else if (self.pinboard != nil)
            self.emptyLabel.text = @"Pinboard is empty\nDrag items here, or use Pin in an item's menu.";
        else
            self.emptyLabel.text = @"Nothing copied yet\nEverything you copy in iSH, or in other apps before switching back, shows up here.";
    }
}

- (void)configureCell:(ClipCardCell *)cell identifier:(NSString *)identifier {
    ClipItem *item = self.itemsByID[identifier];
    if (item == nil)
        return;
    ClipPinboard *pinboard = item.pinboardID != nil && (self.searching || self.pinboard == nil)
        ? [ClipboardStore.shared pinboardWithID:item.pinboardID] : nil;
    [cell configureWithItem:item pinboard:pinboard];
    cell.cardSelected = [self.selection containsObject:identifier];
    cell.shortcutNumber = self.commandHeld ? [self shortcutNumberForIdentifier:identifier] : 0;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"clip %lu", (unsigned long) [self.displayed indexOfObject:item] + 1];
}

- (NSArray<ClipItem *> *)selectedItems {
    NSMutableArray<ClipItem *> *items = [NSMutableArray new];
    // In display order, which is the order they paste in.
    for (ClipItem *item in self.displayed) {
        if ([self.selection containsObject:item.identifier])
            [items addObject:item];
    }
    return items;
}

- (NSUInteger)indexOfItemID:(NSString *)identifier {
    ClipItem *item = identifier ? self.itemsByID[identifier] : nil;
    return item ? [self.displayed indexOfObject:item] : NSNotFound;
}

#pragma mark Selection

- (void)selectionDidChange {
    for (NSIndexPath *indexPath in self.cards.indexPathsForVisibleItems) {
        ClipCardCell *cell = (ClipCardCell *) [self.cards cellForItemAtIndexPath:indexPath];
        NSString *identifier = [self.dataSource itemIdentifierForIndexPath:indexPath];
        cell.cardSelected = identifier != nil && [self.selection containsObject:identifier];
    }
}

- (void)selectOnly:(ClipItem *)item scroll:(BOOL)scroll {
    [self.selection removeAllObjects];
    if (item != nil)
        [self.selection addObject:item.identifier];
    self.anchor = item.identifier;
    [self selectionDidChange];
    if (scroll && item != nil)
        [self scrollToIndex:[self.displayed indexOfObject:item]];
}

- (void)selectRangeTo:(NSUInteger)index {
    NSUInteger anchor = [self indexOfItemID:self.anchor];
    if (anchor == NSNotFound)
        anchor = index;
    [self.selection removeAllObjects];
    for (NSUInteger i = MIN(anchor, index); i <= MAX(anchor, index) && i < self.displayed.count; i++)
        [self.selection addObject:self.displayed[i].identifier];
    [self selectionDidChange];
    [self scrollToIndex:index];
}

- (void)scrollToIndex:(NSUInteger)index {
    if (index >= self.displayed.count)
        return;
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:(NSInteger) index inSection:0];
    UICollectionViewLayoutAttributes *attributes = [self.cards layoutAttributesForItemAtIndexPath:indexPath];
    if (attributes == nil)
        return;
    [self.cards scrollRectToVisible:CGRectInset(attributes.frame, -kCardInset, 0) animated:YES];
}

// The selected item furthest along in the direction of movement, for arrow keys.
- (NSUInteger)cursorIndex {
    NSUInteger index = [self indexOfItemID:self.selection.lastObject];
    return index == NSNotFound ? 0 : index;
}

- (void)moveSelectionBy:(NSInteger)offset extend:(BOOL)extend {
    if (self.displayed.count == 0)
        return;
    NSInteger target = (NSInteger) [self cursorIndex] + offset;
    target = MAX(0, MIN(target, (NSInteger) self.displayed.count - 1));
    [self moveSelectionTo:(NSUInteger) target extend:extend];
}

- (void)moveSelectionTo:(NSUInteger)index extend:(BOOL)extend {
    if (index >= self.displayed.count)
        return;
    if (extend) {
        NSString *anchor = self.anchor;
        [self selectRangeTo:index];
        // Keep the moving end last, so the next arrow continues from it.
        NSString *moving = self.displayed[index].identifier;
        [self.selection removeObject:moving];
        [self.selection addObject:moving];
        self.anchor = anchor;
    } else {
        [self selectOnly:self.displayed[index] scroll:YES];
    }
}

- (void)cardsTapped:(UITapGestureRecognizer *)recognizer {
    [self becomeFirstResponder];
    NSIndexPath *indexPath = [self.cards indexPathForItemAtPoint:[recognizer locationInView:self.cards]];
    if (indexPath == nil || (NSUInteger) indexPath.item >= self.displayed.count)
        return;
    ClipItem *item = self.displayed[(NSUInteger) indexPath.item];
    UIKeyModifierFlags modifiers = 0;
    if (@available(iOS 13.4, *))
        modifiers = recognizer.modifierFlags;
    if (modifiers & UIKeyModifierShift) {
        [self selectRangeTo:(NSUInteger) indexPath.item];
    } else if ((modifiers & UIKeyModifierCommand) || self.selectMode) {
        if ([self.selection containsObject:item.identifier])
            [self.selection removeObject:item.identifier];
        else
            [self.selection addObject:item.identifier];
        self.anchor = item.identifier;
        [self selectionDidChange];
    } else if (self.selection.count == 1 && [self.selection containsObject:item.identifier]) {
        // A second tap (or a double click) pastes.
        [self pasteItems:@[item] plainText:NO];
    } else {
        [self selectOnly:item scroll:NO];
    }
}

#pragma mark Actions on items

- (void)pasteItems:(NSArray<ClipItem *> *)items plainText:(BOOL)plainText {
    if (items.count == 0)
        return;
    ClipboardStore *store = ClipboardStore.shared;
    ClipboardPreferences *prefs = ClipboardPreferences.shared;
    plainText |= prefs.alwaysPlainText;
    NSString *text = [store textForItems:items];
    [store copyItems:items plainText:plainText];
    if (prefs.soundEffects)
        AudioServicesPlaySystemSound(1105);
    UIView *host = self.superview;
    [self.delegate shelfDidRequestClose:self];
    if (prefs.pasteToClipboardOnly || text == nil) {
        ClipShowToast(host, items.count == 1 && items.firstObject.kind == ClipKindImage ? @"Image Copied" : @"Copied", @"doc.on.clipboard");
        return;
    }
    [self.delegate shelf:self pasteText:text];
}

- (void)pasteSelection:(BOOL)plainText {
    [self pasteItems:self.selectedItems plainText:plainText];
}

- (void)copyItems:(NSArray<ClipItem *> *)items plainText:(BOOL)plainText {
    if (items.count == 0)
        return;
    [ClipboardStore.shared copyItems:items plainText:plainText];
    ClipShowToast(self.superview, items.count == 1 ? @"Copied" : [NSString stringWithFormat:@"Copied %lu Items", (unsigned long) items.count], @"doc.on.doc");
}

- (void)deleteItems:(NSArray<ClipItem *> *)items {
    if (items.count == 0)
        return;
    NSUInteger index = [self.displayed indexOfObject:items.firstObject];
    [ClipboardStore.shared deleteItems:items];
    if (self.displayed.count > 0)
        [self selectOnly:self.displayed[MIN(index, self.displayed.count - 1)] scroll:YES];
}

- (void)pinItems:(NSArray<ClipItem *> *)items toPinboard:(ClipPinboard *)pinboard {
    if (items.count == 0)
        return;
    [ClipboardStore.shared pinItems:items toPinboard:pinboard atIndex:0];
    ClipShowToast(self.superview, [@"Pinned to " stringByAppendingString:pinboard.name], @"pin");
}

- (UIViewController *)presenter {
    UIViewController *vc = [self.delegate presentingViewControllerForShelf:self];
    while (vc.presentedViewController != nil)
        vc = vc.presentedViewController;
    return vc;
}

- (void)presentItemController:(ClipboardItemViewController *)controller {
    __weak typeof(self) weakSelf = self;
    controller.pasteHandler = ^(NSArray<ClipItem *> *items, BOOL plainText) {
        [weakSelf pasteItems:items plainText:plainText];
    };
    controller.dismissHandler = ^{
        [weakSelf becomeFirstResponder];
    };
    [self.presenter presentViewController:controller animated:YES completion:nil];
}

- (void)previewItem:(ClipItem *)item {
    if (item == nil)
        return;
    NSUInteger index = [self.displayed indexOfObject:item];
    [self presentItemController:[[ClipboardItemViewController alloc] initWithItems:self.displayed index:index == NSNotFound ? 0 : index]];
}

- (void)editItem:(ClipItem *)item {
    if (item == nil)
        return;
    [self presentItemController:[[ClipboardItemViewController alloc] initForEditingItem:item]];
}

- (void)newTextItem {
    [self presentItemController:[[ClipboardItemViewController alloc] initForNewItemInPinboard:self.searching ? nil : self.pinboard]];
}

- (void)openItem:(ClipItem *)item {
    if (item.kind == ClipKindLink && item.URL != nil)
        [UIApplication openURL:item.URL.absoluteString];
    else
        [self previewItem:item];
}

- (void)shareItems:(NSArray<ClipItem *> *)items from:(nullable UIView *)source {
    NSMutableArray *activityItems = [NSMutableArray new];
    for (ClipItem *item in items) {
        if (item.kind == ClipKindImage) {
            UIImage *image = [item loadImage];
            if (image)
                [activityItems addObject:image];
        } else if (item.kind == ClipKindLink && item.URL) {
            [activityItems addObject:item.URL];
        } else if (item.text) {
            [activityItems addObject:item.text];
        }
    }
    if (activityItems.count == 0)
        return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:activityItems applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: self;
    share.popoverPresentationController.sourceRect = (source ?: self).bounds;
    __weak typeof(self) weakSelf = self;
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *returned, NSError *error) {
        [weakSelf becomeFirstResponder];
    };
    [self.presenter presentViewController:share animated:YES completion:nil];
}

- (void)promptRenameItem:(ClipItem *)item {
    if (item == nil)
        return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Item" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item.title;
        field.placeholder = item.displayTitle;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf becomeFirstResponder];
    }]];
    UIAlertAction *rename = [UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [ClipboardStore.shared renameItem:item title:weakAlert.textFields.firstObject.text];
        [weakSelf becomeFirstResponder];
    }];
    [alert addAction:rename];
    alert.preferredAction = rename;
    [self.presenter presentViewController:alert animated:YES completion:nil];
}

// Leaves search and shows the item where it lives.
- (void)jumpToItem:(ClipItem *)item {
    if (item == nil)
        return;
    if (self.searching)
        [self endSearch];
    self.pinboard = item.pinboardID ? [ClipboardStore.shared pinboardWithID:item.pinboardID] : nil;
    [self.tabs reloadData];
    [self reloadAnimated:NO];
    [self.cards layoutIfNeeded];
    ClipItem *shown = self.itemsByID[item.identifier];
    [self selectOnly:shown ?: self.displayed.firstObject scroll:YES];
    [self scrollToSelectedTab];
}

#pragma mark Pinboards

- (NSInteger)selectedTabIndex {
    if (self.pinboard == nil)
        return 0;
    NSUInteger index = [ClipboardStore.shared.pinboards indexOfObject:self.pinboard];
    return index == NSNotFound ? 0 : (NSInteger) index + 1;
}

- (void)showTabAtIndex:(NSInteger)index {
    NSArray<ClipPinboard *> *pinboards = ClipboardStore.shared.pinboards;
    NSInteger count = (NSInteger) pinboards.count + 1;
    index = ((index % count) + count) % count;
    ClipPinboard *pinboard = index == 0 ? nil : pinboards[(NSUInteger) index - 1];
    if (self.searching)
        [self endSearch];
    self.pinboard = pinboard;
    [self.tabs reloadData];
    [self reloadAnimated:NO];
    [self.cards setContentOffset:CGPointZero animated:NO];
    [self selectOnly:self.displayed.firstObject scroll:NO];
    [self scrollToSelectedTab];
}

- (void)scrollToSelectedTab {
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:[self selectedTabIndex] inSection:0];
    if ([self.tabs numberOfItemsInSection:0] > indexPath.item)
        [self.tabs scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionCenteredHorizontally animated:YES];
}

- (void)promptForNewPinboard {
    [self promptForPinboardName:nil title:@"New Pinboard" action:@"Create" completion:^(NSString *name) {
        ClipboardStore *store = ClipboardStore.shared;
        NSArray<ClipItem *> *selected = self.selectMode ? self.selectedItems : @[];
        ClipPinboard *pinboard = [store createPinboardNamed:name colorIndex:[store suggestedColorIndex]];
        if (selected.count > 0)
            [store pinItems:selected toPinboard:pinboard atIndex:0];
        self.selectMode = NO;
        [self showTabAtIndex:(NSInteger) [store.pinboards indexOfObject:pinboard] + 1];
    }];
}

- (void)promptForPinboardName:(NSString *)current title:(NSString *)title action:(NSString *)actionTitle completion:(void (^)(NSString *name))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf becomeFirstResponder];
    }]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length > 0)
            completion(name);
        [weakSelf becomeFirstResponder];
    }];
    [alert addAction:ok];
    alert.preferredAction = ok;
    [self.presenter presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeletePinboard:(ClipPinboard *)pinboard {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete “%@”?", pinboard.name]
                                                                   message:@"The pinboard and everything pinned to it will be deleted."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf becomeFirstResponder];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [ClipboardStore.shared deletePinboard:pinboard];
        [weakSelf showTabAtIndex:0];
        [weakSelf becomeFirstResponder];
    }]];
    [self.presenter presentViewController:alert animated:YES completion:nil];
}

- (void)confirmEraseHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Erase History?"
                                                                   message:@"Everything in the clipboard history will be deleted. Pinned items stay."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf becomeFirstResponder];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Erase" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [ClipboardStore.shared eraseHistory];
        [weakSelf becomeFirstResponder];
    }]];
    [self.presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Menus

static UIAction *Action(NSString *title, NSString *symbol, void (^handler)(void)) {
    return [UIAction actionWithTitle:title image:symbol ? [UIImage systemImageNamed:symbol] : nil identifier:nil handler:^(UIAction *action) {
        handler();
    }];
}

static UIMenu *Inline(NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
}

- (NSArray<UIMenuElement *> *)pauseMenuElements {
    ClipboardStore *store = ClipboardStore.shared;
    if (store.paused)
        return @[Action(@"Resume Capture", @"play", ^{ [store resume]; })];
    return @[[UIMenu menuWithTitle:@"Pause Capture" image:[UIImage systemImageNamed:@"pause"] identifier:nil options:0 children:@[
        Action(@"Until Resumed", nil, ^{ [store pauseFor:0]; }),
        Action(@"For 5 Minutes", nil, ^{ [store pauseFor:5 * 60]; }),
        Action(@"For 1 Hour", nil, ^{ [store pauseFor:3600]; }),
    ]]];
}

- (NSArray<UIMenuElement *> *)moreMenuElements {
    __weak typeof(self) weakSelf = self;
    ClipboardStore *store = ClipboardStore.shared;
    NSMutableArray<UIMenuElement *> *sizes = [NSMutableArray new];
    NSArray<NSString *> *sizeNames = @[@"Compact", @"Regular", @"Large"];
    for (NSInteger i = 0; i < 3; i++) {
        UIAction *action = Action(sizeNames[(NSUInteger) i], nil, ^{
            ClipboardPreferences.shared.cardSize = i;
        });
        action.state = ClipboardPreferences.shared.cardSize == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sizes addObject:action];
    }
    UIAction *select = self.selectMode
        ? Action(@"Done Selecting", @"checkmark.circle", ^{ weakSelf.selectMode = NO; [weakSelf selectOnly:weakSelf.selectedItems.firstObject scroll:NO]; })
        : Action(@"Select", @"checkmark.circle", ^{ weakSelf.selectMode = YES; });
    UIAction *stack = Action(store.stackActive ? @"Close Paste Stack" : @"Paste Stack", @"square.stack.3d.up", ^{
        [weakSelf.delegate shelfDidRequestPasteStack:weakSelf];
    });
    return @[
        Inline(@[
            Action(@"New Text Item", @"square.and.pencil", ^{ [weakSelf newTextItem]; }),
            Action(@"New Pinboard", @"plus.rectangle.on.rectangle", ^{ [weakSelf promptForNewPinboard]; }),
        ]),
        Inline(@[select, stack]),
        Inline([self pauseMenuElements]),
        Inline(@[
            [UIMenu menuWithTitle:@"Card Size" image:[UIImage systemImageNamed:@"square.resize"] identifier:nil options:0 children:sizes],
            Action(@"Clipboard Settings…", @"gear", ^{ [weakSelf openSettings]; }),
        ]),
    ];
}

- (void)openSettings {
    [self.delegate shelfDidRequestSettings:self];
}

- (UIMenu *)menuForItems:(NSArray<ClipItem *> *)items sourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    ClipboardStore *store = ClipboardStore.shared;
    ClipItem *first = items.firstObject;
    BOOL single = items.count == 1;
    BOOL anyText = [store textForItems:items] != nil;

    NSMutableArray<UIMenuElement *> *pinTargets = [NSMutableArray new];
    for (ClipPinboard *pinboard in store.pinboards) {
        UIImage *dot = [[UIImage systemImageNamed:@"circle.fill"] imageWithTintColor:pinboard.color renderingMode:UIImageRenderingModeAlwaysOriginal];
        UIAction *action = [UIAction actionWithTitle:pinboard.name image:dot identifier:nil handler:^(UIAction *a) {
            [weakSelf pinItems:items toPinboard:pinboard];
        }];
        if (single && [first.pinboardID isEqualToString:pinboard.identifier])
            action.attributes = UIMenuElementAttributesDisabled;
        [pinTargets addObject:action];
    }
    [pinTargets addObject:Inline(@[Action(@"New Pinboard…", @"plus", ^{
        [weakSelf promptForPinboardName:nil title:@"New Pinboard" action:@"Create" completion:^(NSString *name) {
            ClipPinboard *pinboard = [store createPinboardNamed:name colorIndex:[store suggestedColorIndex]];
            [weakSelf pinItems:items toPinboard:pinboard];
        }];
    })])];

    NSMutableArray<UIMenuElement *> *use = [NSMutableArray new];
    BOOL toClipboard = ClipboardPreferences.shared.pasteToClipboardOnly;
    [use addObject:Action(toClipboard ? @"Paste to Clipboard" : @"Paste", @"arrow.down.doc", ^{ [weakSelf pasteItems:items plainText:NO]; })];
    if (anyText)
        [use addObject:Action(@"Paste as Plain Text", @"textformat", ^{ [weakSelf pasteItems:items plainText:YES]; })];
    [use addObject:Action(@"Copy", @"doc.on.doc", ^{ [weakSelf copyItems:items plainText:NO]; })];
    if (anyText && (first.hasRichText || !single))
        [use addObject:Action(@"Copy as Plain Text", nil, ^{ [weakSelf copyItems:items plainText:YES]; })];

    NSMutableArray<UIMenuElement *> *organize = [NSMutableArray new];
    [organize addObject:[UIMenu menuWithTitle:@"Pin to" image:[UIImage systemImageNamed:@"pin"] identifier:nil options:0 children:pinTargets]];
    if (single && self.searching) {
        NSString *where = first.pinboardID ? [store pinboardWithID:first.pinboardID].name : @"Clipboard";
        [organize addObject:Action([NSString stringWithFormat:@"Show in %@", where], @"arrow.right.circle", ^{ [weakSelf jumpToItem:first]; })];
    }

    NSMutableArray<UIMenuElement *> *item = [NSMutableArray new];
    if (single) {
        [item addObject:Action(@"Preview", @"eye", ^{ [weakSelf previewItem:first]; })];
        if (first.kind == ClipKindLink)
            [item addObject:Action(@"Open Link", @"safari", ^{ [weakSelf openItem:first]; })];
        [item addObject:Action(@"Rename…", @"character.cursor.ibeam", ^{ [weakSelf promptRenameItem:first]; })];
        if (first.kind != ClipKindFile)
            [item addObject:Action(@"Edit…", @"pencil", ^{ [weakSelf editItem:first]; })];
    }
    [item addObject:Action(@"Share…", @"square.and.arrow.up", ^{ [weakSelf shareItems:items from:sourceView]; })];

    BOOL allPinned = YES;
    for (ClipItem *each in items)
        allPinned &= each.pinboardID != nil;
    UIAction *delete = Action(allPinned ? @"Unpin" : @"Delete", allPinned ? @"pin.slash" : @"trash", ^{ [weakSelf deleteItems:items]; });
    delete.attributes = UIMenuElementAttributesDestructive;

    NSString *title = single ? @"" : [NSString stringWithFormat:@"%lu Items", (unsigned long) items.count];
    return [UIMenu menuWithTitle:title children:@[Inline(use), Inline(organize), Inline(item), Inline(@[delete])]];
}

- (UIMenu *)menuForTabAtIndex:(NSInteger)index {
    __weak typeof(self) weakSelf = self;
    ClipboardStore *store = ClipboardStore.shared;
    if (index == 0) {
        UIAction *erase = Action(@"Erase History…", @"trash", ^{ [weakSelf confirmEraseHistory]; });
        erase.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[Inline([self pauseMenuElements]), Inline(@[erase])]];
    }
    ClipPinboard *pinboard = store.pinboards[(NSUInteger) index - 1];
    NSMutableArray<UIMenuElement *> *colors = [NSMutableArray new];
    NSArray<UIColor *> *palette = ClipPinboardColors();
    [ClipPinboardColorNames() enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        UIImage *dot = [[UIImage systemImageNamed:@"circle.fill"] imageWithTintColor:palette[i] renderingMode:UIImageRenderingModeAlwaysOriginal];
        UIAction *action = [UIAction actionWithTitle:name image:dot identifier:nil handler:^(UIAction *a) {
            [store setColorIndex:(NSInteger) i ofPinboard:pinboard];
        }];
        action.state = pinboard.colorIndex == (NSInteger) i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [colors addObject:action];
    }];
    NSUInteger position = (NSUInteger) index - 1;
    UIAction *left = Action(@"Move Left", @"arrow.left", ^{ [store movePinboard:pinboard toIndex:position - 1]; });
    if (position == 0)
        left.attributes = UIMenuElementAttributesDisabled;
    UIAction *right = Action(@"Move Right", @"arrow.right", ^{ [store movePinboard:pinboard toIndex:position + 1]; });
    if (position + 1 >= store.pinboards.count)
        right.attributes = UIMenuElementAttributesDisabled;
    UIAction *delete = Action(@"Delete Pinboard…", @"trash", ^{ [weakSelf confirmDeletePinboard:pinboard]; });
    delete.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:pinboard.name children:@[
        Inline(@[
            Action(@"Rename…", @"pencil", ^{
                [weakSelf promptForPinboardName:pinboard.name title:@"Rename Pinboard" action:@"Rename" completion:^(NSString *name) {
                    [store renamePinboard:pinboard name:name];
                }];
            }),
            [UIMenu menuWithTitle:@"Color" image:[UIImage systemImageNamed:@"paintpalette"] identifier:nil options:0 children:colors],
        ]),
        Inline(@[left, right]),
        Inline(@[delete]),
    ]];
}

#pragma mark Search

- (void)searchButtonTapped {
    if (self.searching)
        [self endSearch];
    else
        [self beginSearch];
}

- (void)beginSearch {
    if (self.searching) {
        // ⌘F again shows every filter.
        [self.searchField becomeFirstResponder];
        [self showFilterSuggestionsMatching:nil];
        return;
    }
    self.searching = YES;
    self.searchField.hidden = NO;
    self.filterButton.hidden = NO;
    self.tabs.hidden = YES;
    self.addButton.hidden = YES;
    self.searchField.text = @"";
    self.searchField.tokens = @[];
    // Search starts scoped to the pinboard being shown.
    if (self.pinboard != nil)
        [self addFilter:[self filterForPinboard:self.pinboard]];
    [self updateQuery];
    [self.searchField becomeFirstResponder];
}

- (void)endSearch {
    self.searching = NO;
    self.searchField.hidden = YES;
    self.filterButton.hidden = YES;
    self.tabs.hidden = NO;
    self.addButton.hidden = NO;
    if (self.searchField.isFirstResponder)
        [self becomeFirstResponder];
    [self reloadAnimated:NO];
    [self selectOnly:self.displayed.firstObject scroll:YES];
}

- (void)searchChanged {
    [self updateQuery];
    [self showFilterSuggestionsMatching:[self lastWordOfSearch]];
}

- (NSString *)lastWordOfSearch {
    NSString *text = self.searchField.text ?: @"";
    NSRange space = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet options:NSBackwardsSearch];
    return space.location == NSNotFound ? text : [text substringFromIndex:space.location + 1];
}

- (void)updateQuery {
    ClipQuery *query = [ClipQuery new];
    query.text = self.searchField.text ?: @"";
    NSMutableSet *kinds = [NSMutableSet new], *sources = [NSMutableSet new], *pinboards = [NSMutableSet new];
    for (UISearchToken *token in self.searchField.tokens) {
        ClipFilter *filter = token.representedObject;
        switch (filter.type) {
            case FilterKind: [kinds addObject:filter.value]; break;
            case FilterSource: [sources addObject:filter.value]; break;
            case FilterPinboard: [pinboards addObject:filter.value]; break;
            case FilterDate: query.date = [filter.value integerValue]; break;
        }
    }
    query.kinds = kinds;
    query.sources = sources;
    query.pinboardIDs = pinboards;
    self.query = query;
    [self reloadAnimated:NO];
    [self.cards setContentOffset:CGPointZero animated:NO];
    [self selectOnly:self.displayed.firstObject scroll:NO];
}

- (NSArray<ClipFilter *> *)allFilters {
    NSMutableArray<ClipFilter *> *filters = [NSMutableArray new];
    for (NSNumber *kind in @[@(ClipKindText), @(ClipKindLink), @(ClipKindImage), @(ClipKindFile), @(ClipKindColor)]) {
        ClipFilter *filter = [ClipFilter new];
        filter.type = FilterKind;
        filter.value = kind;
        filter.title = ClipKindName(kind.integerValue);
        filter.symbol = ClipKindSymbol(kind.integerValue);
        [filters addObject:filter];
    }
    for (NSNumber *source in @[@(ClipSourceTerminal), @(ClipSourceLinux), @(ClipSourceOtherApp), @(ClipSourceCreated)]) {
        ClipFilter *filter = [ClipFilter new];
        filter.type = FilterSource;
        filter.value = source;
        filter.title = ClipSourceName(source.integerValue);
        filter.symbol = ClipSourceSymbol(source.integerValue);
        [filters addObject:filter];
    }
    for (NSNumber *date in @[@(ClipDateToday), @(ClipDateYesterday), @(ClipDateLastWeek), @(ClipDateLastMonth)]) {
        ClipFilter *filter = [ClipFilter new];
        filter.type = FilterDate;
        filter.value = date;
        filter.title = ClipDateFilterName(date.integerValue);
        filter.symbol = @"calendar";
        [filters addObject:filter];
    }
    ClipFilter *history = [ClipFilter new];
    history.type = FilterPinboard;
    history.value = @"";
    history.title = @"Clipboard";
    history.symbol = @"clock";
    [filters addObject:history];
    for (ClipPinboard *pinboard in ClipboardStore.shared.pinboards)
        [filters addObject:[self filterForPinboard:pinboard]];
    return filters;
}

- (ClipFilter *)filterForPinboard:(ClipPinboard *)pinboard {
    ClipFilter *filter = [ClipFilter new];
    filter.type = FilterPinboard;
    filter.value = pinboard.identifier;
    filter.title = pinboard.name;
    filter.symbol = @"circle.fill";
    filter.color = pinboard.color;
    return filter;
}

- (UIImage *)imageForFilter:(ClipFilter *)filter {
    UIImage *image = [UIImage systemImageNamed:filter.symbol];
    if (filter.color != nil)
        image = [image imageWithTintColor:filter.color renderingMode:UIImageRenderingModeAlwaysOriginal];
    return image;
}

- (NSArray<ClipFilter *> *)activeFilters {
    NSMutableArray<ClipFilter *> *filters = [NSMutableArray new];
    for (UISearchToken *token in self.searchField.tokens)
        [filters addObject:token.representedObject];
    return filters;
}

- (void)addFilter:(ClipFilter *)filter {
    NSMutableArray<UISearchToken *> *tokens = [self.searchField.tokens mutableCopy];
    for (UISearchToken *token in self.searchField.tokens) {
        ClipFilter *existing = token.representedObject;
        if ([existing isEqual:filter])
            return;
        // Only one date range makes sense.
        if (existing.type == FilterDate && filter.type == FilterDate)
            [tokens removeObject:token];
    }
    UISearchToken *token = [UISearchToken tokenWithIcon:[self imageForFilter:filter] text:filter.title];
    token.representedObject = filter;
    [tokens addObject:token];
    self.searchField.tokens = tokens;
}

- (void)toggleFilter:(ClipFilter *)filter {
    for (UISearchToken *token in self.searchField.tokens) {
        if ([token.representedObject isEqual:filter]) {
            NSMutableArray *tokens = [self.searchField.tokens mutableCopy];
            [tokens removeObject:token];
            self.searchField.tokens = tokens;
            [self updateQuery];
            return;
        }
    }
    [self addFilter:filter];
    [self updateQuery];
}

- (NSArray<UIMenuElement *> *)filterMenuElements {
    __weak typeof(self) weakSelf = self;
    NSArray<ClipFilter *> *active = self.activeFilters;
    NSMutableDictionary<NSNumber *, NSMutableArray<UIMenuElement *> *> *sections = [NSMutableDictionary new];
    for (ClipFilter *filter in self.allFilters) {
        UIAction *action = [UIAction actionWithTitle:filter.title image:[self imageForFilter:filter] identifier:nil handler:^(UIAction *a) {
            [weakSelf toggleFilter:filter];
        }];
        action.state = [active containsObject:filter] ? UIMenuElementStateOn : UIMenuElementStateOff;
        NSNumber *key = @(filter.type);
        if (sections[key] == nil)
            sections[key] = [NSMutableArray new];
        [sections[key] addObject:action];
    }
    NSArray<NSString *> *titles = @[@"Type", @"Source", @"Date", @"Pinboard"];
    NSMutableArray<UIMenuElement *> *menus = [NSMutableArray new];
    for (NSInteger type = FilterKind; type <= FilterPinboard; type++) {
        if (sections[@(type)])
            [menus addObject:[UIMenu menuWithTitle:titles[(NSUInteger) type] image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sections[@(type)]]];
    }
    return menus;
}

// Typing the start of a filter's name offers it, as Paste does ("L" → Link, Last Week…).
- (void)showFilterSuggestionsMatching:(NSString *)prefix {
    if (@available(iOS 16, *)) {
        NSMutableArray<UISearchSuggestionItem *> *suggestions = [NSMutableArray new];
        NSArray<ClipFilter *> *active = self.activeFilters;
        for (ClipFilter *filter in self.allFilters) {
            if ([active containsObject:filter])
                continue;
            if (prefix != nil && (prefix.length == 0 || ![filter.title.lowercaseString hasPrefix:prefix.lowercaseString]))
                continue;
            UISearchSuggestionItem *suggestion = [UISearchSuggestionItem suggestionWithLocalizedSuggestion:filter.title
                                                                                        descriptionString:nil
                                                                                                 iconImage:[self imageForFilter:filter]];
            suggestion.representedObject = filter;
            [suggestions addObject:suggestion];
        }
        self.searchField.searchSuggestions = suggestions.count > 0 ? suggestions : nil;
    }
}

- (void)searchTextField:(UISearchTextField *)field didSelectSuggestion:(id<UISearchSuggestion>)suggestion API_AVAILABLE(ios(16.0)) {
    ClipFilter *filter = suggestion.representedObject;
    if (![filter isKindOfClass:ClipFilter.class])
        return;
    // The typed word becomes the token.
    NSString *text = field.text ?: @"";
    NSString *word = [self lastWordOfSearch];
    if (word.length > 0 && [filter.title.lowercaseString hasPrefix:word.lowercaseString])
        field.text = [[text substringToIndex:text.length - word.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self addFilter:filter];
    field.searchSuggestions = nil;
    [self updateQuery];
}

- (void)textFieldDidChangeSelection:(UITextField *)textField {
    // Deleting a token by backspace changes the tokens without an editing event.
    if (textField == self.searchField && self.searchField.tokens.count != self.query.kinds.count + self.query.sources.count +
        self.query.pinboardIDs.count + (self.query.date != ClipDateAny))
        [self updateQuery];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // Return moves to the results; Return again pastes.
    [self focusResults];
    return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (@available(iOS 16, *))
        self.searchField.searchSuggestions = nil;
}

- (void)focusResults {
    [self becomeFirstResponder];
    if (self.selection.count == 0)
        [self selectOnly:self.displayed.firstObject scroll:YES];
}

#pragma mark Keyboard

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// Taking text input is what gets keys delivered while the shelf is focused when
// the keyboard is on screen (and in the Simulator); the empty input view keeps the
// on-screen keyboard away. Typed text starts a search, as in Paste.
- (UIView *)inputView {
    static UIView *empty;
    if (empty == nil)
        empty = [[UIView alloc] initWithFrame:CGRectZero];
    return empty;
}

- (BOOL)hasText {
    return YES;
}

- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"] || [text isEqualToString:@"\r"]) {
        [self pasteSelection:NO];
    } else if ([text isEqualToString:@" "]) {
        [self previewItem:self.selectedItems.firstObject];
    } else if ([text isEqualToString:@"\t"]) {
        [self tabPressed:nil];
    } else if (text.length > 0) {
        [self beginSearch];
        self.searchField.text = [(self.searchField.text ?: @"") stringByAppendingString:text];
        [self searchChanged];
    }
}

- (void)deleteBackward {
    [self deleteItems:self.selectedItems];
}

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

static UIKeyCommand *KeyCommand(NSString *input, UIKeyModifierFlags modifiers, SEL action, NSString *title) {
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:input modifierFlags:modifiers action:action];
    if (title != nil)
        command.discoverabilityTitle = title;
    command.wantsPriorityOverSystemBehavior = YES;
    return command;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray new];
    [commands addObject:KeyCommand(UIKeyInputEscape, 0, @selector(escapePressed:), nil)];
    [commands addObject:KeyCommand(@"f", UIKeyModifierCommand, @selector(findPressed:), @"Search")];
    [commands addObject:KeyCommand(@"\t", 0, @selector(tabPressed:), nil)];
    if (self.searchField.isFirstResponder)
        return commands;
    [commands addObjectsFromArray:@[
        KeyCommand(UIKeyInputLeftArrow, 0, @selector(leftPressed:), nil),
        KeyCommand(UIKeyInputRightArrow, 0, @selector(rightPressed:), nil),
        KeyCommand(UIKeyInputLeftArrow, UIKeyModifierShift, @selector(extendLeftPressed:), nil),
        KeyCommand(UIKeyInputRightArrow, UIKeyModifierShift, @selector(extendRightPressed:), nil),
        KeyCommand(UIKeyInputUpArrow, UIKeyModifierCommand, @selector(firstPressed:), @"First Item"),
        KeyCommand(UIKeyInputDownArrow, UIKeyModifierCommand, @selector(lastPressed:), @"Last Item"),
        KeyCommand(UIKeyInputLeftArrow, UIKeyModifierCommand, @selector(previousPinboardPressed:), @"Previous Pinboard"),
        KeyCommand(UIKeyInputRightArrow, UIKeyModifierCommand, @selector(nextPinboardPressed:), @"Next Pinboard"),
        KeyCommand(@"\r", 0, @selector(returnPressed:), @"Paste"),
        KeyCommand(@"\r", UIKeyModifierShift, @selector(shiftReturnPressed:), @"Paste as Plain Text"),
        KeyCommand(@" ", 0, @selector(spacePressed:), @"Preview"),
        KeyCommand(@"\b", 0, @selector(deletePressed:), @"Delete"),
        KeyCommand(UIKeyInputDelete, 0, @selector(deletePressed:), nil),
        KeyCommand(@"o", UIKeyModifierCommand, @selector(openPressed:), @"Open"),
        KeyCommand(@"r", UIKeyModifierCommand, @selector(renamePressed:), @"Rename"),
        KeyCommand(@"e", UIKeyModifierCommand, @selector(editPressed:), @"Edit"),
        KeyCommand(@"g", UIKeyModifierCommand, @selector(jumpPressed:), @"Show in Pinboard"),
        KeyCommand(@"z", UIKeyModifierCommand, @selector(undoPressed:), @"Undo"),
        KeyCommand(@"z", UIKeyModifierCommand | UIKeyModifierShift, @selector(redoPressed:), @"Redo"),
    ]];
    // ⌘1–9 (and ⌘T, ⌘N, ⇧⌘N, ⌘A, ⌘C) are main menu shortcuts; the matching actions below
    // take them over while the shelf is focused. Plain-text quick paste is ours.
    for (int i = 1; i <= 9; i++) {
        [commands addObject:KeyCommand([NSString stringWithFormat:@"%d", i], UIKeyModifierCommand | UIKeyModifierShift,
                                       @selector(quickPastePlainPressed:), nil)];
    }
    return commands;
}

- (void)escapePressed:(id)sender {
    if (self.searching)
        [self endSearch];
    else if (self.selectMode) {
        self.selectMode = NO;
        [self selectOnly:self.selectedItems.firstObject scroll:NO];
    } else
        [self.delegate shelfDidRequestClose:self];
}
- (void)findPressed:(id)sender { [self beginSearch]; }
- (void)tabPressed:(id)sender {
    if (!self.searching)
        return;
    if (self.searchField.isFirstResponder)
        [self focusResults];
    else
        [self.searchField becomeFirstResponder];
}
- (void)leftPressed:(id)sender { [self moveSelectionBy:-1 extend:NO]; }
- (void)rightPressed:(id)sender { [self moveSelectionBy:1 extend:NO]; }
- (void)extendLeftPressed:(id)sender { [self moveSelectionBy:-1 extend:YES]; }
- (void)extendRightPressed:(id)sender { [self moveSelectionBy:1 extend:YES]; }
- (void)firstPressed:(id)sender { [self moveSelectionTo:0 extend:NO]; }
- (void)lastPressed:(id)sender {
    if (self.displayed.count > 0)
        [self moveSelectionTo:self.displayed.count - 1 extend:NO];
}
- (void)previousPinboardPressed:(id)sender { [self showTabAtIndex:[self selectedTabIndex] - 1]; }
- (void)nextPinboardPressed:(id)sender { [self showTabAtIndex:[self selectedTabIndex] + 1]; }
- (void)returnPressed:(id)sender { [self pasteSelection:NO]; }
- (void)shiftReturnPressed:(id)sender { [self pasteSelection:YES]; }
- (void)spacePressed:(id)sender { [self previewItem:self.selectedItems.firstObject]; }
- (void)deletePressed:(id)sender { [self deleteItems:self.selectedItems]; }
- (void)openPressed:(id)sender { [self openItem:self.selectedItems.firstObject]; }
- (void)renamePressed:(id)sender { [self promptRenameItem:self.selectedItems.firstObject]; }
- (void)editPressed:(id)sender { [self editItem:self.selectedItems.firstObject]; }
- (void)jumpPressed:(id)sender { [self jumpToItem:self.selectedItems.firstObject]; }
- (void)newPinboard:(id)sender { [self promptForNewPinboard]; }
- (void)undoPressed:(id)sender {
    NSUndoManager *undo = ClipboardStore.shared.undoManager;
    if (undo.canUndo) {
        NSString *name = undo.undoActionName;
        [undo undo];
        ClipShowToast(self.superview, name.length ? [@"Undo " stringByAppendingString:name] : @"Undo", @"arrow.uturn.backward");
    }
}
- (void)redoPressed:(id)sender {
    NSUndoManager *undo = ClipboardStore.shared.undoManager;
    if (undo.canRedo) {
        NSString *name = undo.redoActionName;
        [undo redo];
        ClipShowToast(self.superview, name.length ? [@"Redo " stringByAppendingString:name] : @"Redo", @"arrow.uturn.forward");
    }
}

- (void)quickPasteNumber:(NSInteger)number plainText:(BOOL)plainText {
    ClipItem *item = [self itemForShortcutNumber:number];
    if (item != nil)
        [self pasteItems:@[item] plainText:plainText];
}

- (void)quickPastePlainPressed:(UIKeyCommand *)sender {
    [self quickPasteNumber:sender.input.integerValue plainText:YES];
}

// Numbers count from the first card in view, so ⌘1 is always the leftmost one shown.
- (NSUInteger)firstVisibleIndex {
    CGFloat left = self.cards.contentOffset.x + kCardInset / 2;
    NSUInteger first = NSNotFound;
    for (NSIndexPath *indexPath in self.cards.indexPathsForVisibleItems) {
        UICollectionViewLayoutAttributes *attributes = [self.cards layoutAttributesForItemAtIndexPath:indexPath];
        if (CGRectGetMinX(attributes.frame) >= left - 1)
            first = MIN(first, (NSUInteger) indexPath.item);
    }
    return first == NSNotFound ? 0 : first;
}

- (ClipItem *)itemForShortcutNumber:(NSInteger)number {
    NSUInteger index = [self firstVisibleIndex] + (NSUInteger) number - 1;
    return number >= 1 && number <= 9 && index < self.displayed.count ? self.displayed[index] : nil;
}

- (NSInteger)shortcutNumberForIdentifier:(NSString *)identifier {
    NSUInteger index = [self indexOfItemID:identifier];
    NSUInteger first = [self firstVisibleIndex];
    if (index == NSNotFound || index < first || index - first >= 9)
        return 0;
    return (NSInteger) (index - first) + 1;
}

// The main menu's shortcuts that mean something else here.
- (void)selectTabByNumber:(UICommand *)sender {
    [self quickPasteNumber:[sender.propertyList integerValue] + 1 plainText:NO];
}
- (void)newTab:(id)sender {
    ClipboardStore *store = ClipboardStore.shared;
    if (store.paused)
        [store resume];
    else
        [store pauseFor:0];
    ClipShowToast(self.superview, store.paused ? @"Capture Paused" : @"Capture Resumed", store.paused ? @"pause.fill" : @"play.fill");
}
- (void)newWindow:(id)sender { [self newTextItem]; }
- (void)closeCurrentTab:(id)sender { [self.delegate shelfDidRequestClose:self]; }
- (void)copy:(id)sender { [self copyItems:self.selectedItems plainText:NO]; }
- (void)paste:(id)sender { [self pasteSelection:NO]; }
- (void)selectAll:(id)sender {
    for (ClipItem *item in self.displayed)
        [self.selection addObject:item.identifier];
    [self selectionDidChange];
}
- (void)moveTabLeft:(id)sender {}
- (void)moveTabRight:(id)sender {}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(copy:) || action == @selector(paste:))
        return self.selection.count > 0 && !self.searchField.isFirstResponder;
    if (action == @selector(selectAll:))
        return !self.searchField.isFirstResponder;
    return [super canPerformAction:action withSender:sender];
}

- (void)validateCommand:(UICommand *)command {
    [super validateCommand:command];
    if (command.action == @selector(selectTabByNumber:)) {
        NSInteger number = [command.propertyList integerValue] + 1;
        ClipItem *item = [self itemForShortcutNumber:number];
        command.title = item ? [@"Paste " stringByAppendingString:item.displayTitle] : [NSString stringWithFormat:@"Paste Item %ld", (long) number];
        command.attributes = item ? 0 : UIMenuElementAttributesDisabled;
        command.state = UIMenuElementStateOff;
    }
}

// Holding ⌘ shows which card each number pastes.
- (void)updateCommandHeld:(UIPressesEvent *)event {
    BOOL held = (event.modifierFlags & UIKeyModifierCommand) != 0;
    if (held == self.commandHeld)
        return;
    self.commandHeld = held;
    for (NSIndexPath *indexPath in self.cards.indexPathsForVisibleItems) {
        ClipCardCell *cell = (ClipCardCell *) [self.cards cellForItemAtIndexPath:indexPath];
        NSString *identifier = [self.dataSource itemIdentifierForIndexPath:indexPath];
        cell.shortcutNumber = held && identifier ? [self shortcutNumberForIdentifier:identifier] : 0;
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self updateCommandHeld:event];
    [super pressesBegan:presses withEvent:event];
}
- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self updateCommandHeld:event];
    [super pressesChanged:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self updateCommandHeld:event];
    [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    self.commandHeld = YES;
    [self updateCommandHeld:nil];
    [super pressesCancelled:presses withEvent:event];
}

- (BOOL)resignFirstResponder {
    BOOL result = [super resignFirstResponder];
    if (self.commandHeld) {
        self.commandHeld = YES;
        [self updateCommandHeld:nil];
    }
    return result;
}

#pragma mark Collection views

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger) ClipboardStore.shared.pinboards.count + 1;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ClipTabCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kTabReuse forIndexPath:indexPath];
    if (indexPath.item == 0) {
        [cell configureWithTitle:@"Clipboard" color:nil symbol:@"clock"];
    } else {
        ClipPinboard *pinboard = ClipboardStore.shared.pinboards[(NSUInteger) indexPath.item - 1];
        [cell configureWithTitle:pinboard.name color:pinboard.color symbol:nil];
    }
    cell.tabSelected = indexPath.item == [self selectedTabIndex];
    cell.dropTarget = [indexPath isEqual:self.dropTargetTab];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView == self.tabs) {
        if (indexPath.item == 0)
            return [ClipTabCell sizeForTitle:@"Clipboard" hasIcon:YES];
        ClipPinboard *pinboard = ClipboardStore.shared.pinboards[(NSUInteger) indexPath.item - 1];
        return [ClipTabCell sizeForTitle:pinboard.name hasIcon:YES];
    }
    CGFloat side = MIN([self cardSide], MAX(40, collectionView.bounds.size.height - 8));
    return CGSizeMake(side, side);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout insetForSectionAtIndex:(NSInteger)section {
    if (collectionView == self.tabs) {
        // Tabs sit centered while they fit, as in Paste.
        CGFloat total = 0;
        NSInteger count = [self collectionView:collectionView numberOfItemsInSection:0];
        for (NSInteger i = 0; i < count; i++)
            total += [self collectionView:collectionView layout:layout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].width + 4;
        CGFloat side = MAX(0, (collectionView.bounds.size.width - total) / 2);
        return UIEdgeInsetsMake(0, side, 0, side);
    }
    return UIEdgeInsetsMake(0, kCardInset, 0, kCardInset);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView == self.tabs) {
        [collectionView deselectItemAtIndexPath:indexPath animated:NO];
        [self showTabAtIndex:indexPath.item];
        [self becomeFirstResponder];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.cards && self.commandHeld) {
        for (NSIndexPath *indexPath in self.cards.indexPathsForVisibleItems) {
            ClipCardCell *cell = (ClipCardCell *) [self.cards cellForItemAtIndexPath:indexPath];
            NSString *identifier = [self.dataSource itemIdentifierForIndexPath:indexPath];
            cell.shortcutNumber = identifier ? [self shortcutNumberForIdentifier:identifier] : 0;
        }
    }
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (collectionView == self.tabs) {
        NSInteger index = indexPath.item;
        return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            return [self menuForTabAtIndex:index];
        }];
    }
    if ((NSUInteger) indexPath.item >= self.displayed.count)
        return nil;
    ClipItem *item = self.displayed[(NSUInteger) indexPath.item];
    // A menu on a selected card acts on the whole selection.
    if (![self.selection containsObject:item.identifier])
        [self selectOnly:item scroll:NO];
    NSArray<ClipItem *> *items = self.selectedItems;
    UIView *cell = [collectionView cellForItemAtIndexPath:indexPath];
    return [UIContextMenuConfiguration configurationWithIdentifier:item.identifier previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [self menuForItems:items sourceView:cell];
    }];
}

#pragma mark Drag and drop

- (NSItemProvider *)itemProviderForItem:(ClipItem *)item {
    NSItemProvider *provider = [NSItemProvider new];
    if (item.kind == ClipKindImage) {
        [provider registerObjectOfClass:UIImage.class visibility:NSItemProviderRepresentationVisibilityAll loadHandler:^NSProgress *(void (^completion)(id<NSItemProviderWriting>, NSError *)) {
            completion([item loadImage], nil);
            return nil;
        }];
    } else if (item.kind == ClipKindLink && item.URL != nil) {
        [provider registerObject:item.URL visibility:NSItemProviderRepresentationVisibilityAll];
        [provider registerObject:item.text visibility:NSItemProviderRepresentationVisibilityAll];
    } else if (item.text != nil) {
        [provider registerObject:item.text visibility:NSItemProviderRepresentationVisibilityAll];
    }
    provider.suggestedName = item.displayTitle;
    return provider;
}

- (NSArray<UIDragItem *> *)collectionView:(UICollectionView *)collectionView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if (collectionView == self.tabs) {
        if (indexPath.item == 0)
            return @[];
        ClipPinboard *pinboard = ClipboardStore.shared.pinboards[(NSUInteger) indexPath.item - 1];
        UIDragItem *drag = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:pinboard.name]];
        drag.localObject = pinboard;
        return @[drag];
    }
    if ((NSUInteger) indexPath.item >= self.displayed.count)
        return @[];
    ClipItem *item = self.displayed[(NSUInteger) indexPath.item];
    NSArray<ClipItem *> *items = [self.selection containsObject:item.identifier] ? self.selectedItems : @[item];
    NSMutableArray<UIDragItem *> *drags = [NSMutableArray new];
    for (ClipItem *each in items) {
        UIDragItem *drag = [[UIDragItem alloc] initWithItemProvider:[self itemProviderForItem:each]];
        drag.localObject = each;
        [drags addObject:drag];
    }
    return drags;
}

- (UIDragPreviewParameters *)collectionView:(UICollectionView *)collectionView dragPreviewParametersForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    UIDragPreviewParameters *parameters = [UIDragPreviewParameters new];
    CGFloat radius = collectionView == self.tabs ? cell.bounds.size.height / 2 : 16;
    parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:cell.bounds cornerRadius:radius];
    parameters.backgroundColor = UIColor.clearColor;
    return parameters;
}

static NSArray<ClipItem *> *LocalItems(id<UIDropSession> session) {
    NSMutableArray<ClipItem *> *items = [NSMutableArray new];
    for (UIDragItem *drag in session.items) {
        if ([drag.localObject isKindOfClass:ClipItem.class])
            [items addObject:drag.localObject];
    }
    return items;
}

static ClipPinboard *LocalPinboard(id<UIDropSession> session) {
    id object = session.items.firstObject.localObject;
    return [object isKindOfClass:ClipPinboard.class] ? object : nil;
}

- (BOOL)collectionView:(UICollectionView *)collectionView canHandleDropSession:(id<UIDropSession>)session {
    if (LocalPinboard(session) != nil)
        return collectionView == self.tabs;
    if (LocalItems(session).count > 0)
        return YES;
    return [session canLoadObjectsOfClass:NSString.class] || [session canLoadObjectsOfClass:UIImage.class] ||
        [session canLoadObjectsOfClass:NSURL.class];
}

- (UICollectionViewDropProposal *)collectionView:(UICollectionView *)collectionView dropSessionDidUpdate:(id<UIDropSession>)session
                                withDestinationIndexPath:(NSIndexPath *)destination {
    if (collectionView == self.tabs) {
        if (LocalPinboard(session) != nil) {
            if (destination == nil || destination.item == 0)
                return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationForbidden];
            return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                                         intent:UICollectionViewDropIntentInsertAtDestinationIndexPath];
        }
        // Items dropped on a tab go into it; highlight the one under the finger.
        NSIndexPath *target = [collectionView indexPathForItemAtPoint:[session locationInView:collectionView]];
        [self setDropTargetTab:target];
        if (target == nil || (target.item == 0 && LocalItems(session).count > 0))
            return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationForbidden];
        return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationCopy
                                                                     intent:UICollectionViewDropIntentInsertIntoDestinationIndexPath];
    }
    if (LocalItems(session).count > 0) {
        // Reordering only means something in a pinboard.
        if (self.pinboard == nil || self.searching || session.items.count != 1)
            return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
        return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                                     intent:UICollectionViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UICollectionViewDropProposal alloc] initWithDropOperation:UIDropOperationCopy
                                                                 intent:UICollectionViewDropIntentInsertAtDestinationIndexPath];
}

- (void)setDropTargetTab:(NSIndexPath *)dropTargetTab {
    if ([dropTargetTab isEqual:_dropTargetTab])
        return;
    NSIndexPath *old = _dropTargetTab;
    _dropTargetTab = dropTargetTab;
    for (NSIndexPath *indexPath in @[old ?: NSNull.null, dropTargetTab ?: NSNull.null]) {
        if (![indexPath isKindOfClass:NSIndexPath.class])
            continue;
        ClipTabCell *cell = (ClipTabCell *) [self.tabs cellForItemAtIndexPath:(NSIndexPath *) indexPath];
        cell.dropTarget = [indexPath isEqual:dropTargetTab];
    }
}

- (void)collectionView:(UICollectionView *)collectionView dropSessionDidExit:(id<UIDropSession>)session {
    if (collectionView == self.tabs)
        self.dropTargetTab = nil;
}

- (void)collectionView:(UICollectionView *)collectionView dropSessionDidEnd:(id<UIDropSession>)session {
    if (collectionView == self.tabs)
        self.dropTargetTab = nil;
}

- (void)collectionView:(UICollectionView *)collectionView performDropWithCoordinator:(id<UICollectionViewDropCoordinator>)coordinator {
    id<UIDropSession> session = coordinator.session;
    ClipboardStore *store = ClipboardStore.shared;
    NSIndexPath *destination = coordinator.destinationIndexPath;
    if (collectionView == self.tabs) {
        ClipPinboard *moving = LocalPinboard(session);
        if (moving != nil) {
            if (destination != nil)
                [store movePinboard:moving toIndex:(NSUInteger) MAX(0, destination.item - 1)];
            return;
        }
        NSIndexPath *target = self.dropTargetTab ?: destination;
        self.dropTargetTab = nil;
        if (target == nil)
            return;
        ClipPinboard *pinboard = target.item == 0 ? nil : store.pinboards[(NSUInteger) target.item - 1];
        NSArray<ClipItem *> *items = LocalItems(session);
        if (items.count > 0 && pinboard != nil)
            [self pinItems:items toPinboard:pinboard];
        else if (items.count == 0)
            [store addItemProviders:[session.items valueForKey:@"itemProvider"] toPinboard:pinboard atIndex:0 completion:nil];
        return;
    }
    NSUInteger index = destination ? (NSUInteger) destination.item : self.displayed.count;
    NSArray<ClipItem *> *items = LocalItems(session);
    if (items.count == 1 && self.pinboard != nil && !self.searching) {
        [store moveItem:items.firstObject toIndex:MIN(index, self.displayed.count - 1)];
        return;
    }
    if (items.count == 0)
        [store addItemProviders:[session.items valueForKey:@"itemProvider"] toPinboard:self.searching ? nil : self.pinboard atIndex:index completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self.cards.collectionViewLayout invalidateLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.tabs.collectionViewLayout invalidateLayout];
}

@end
