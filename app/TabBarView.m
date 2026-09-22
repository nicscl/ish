//
//  TabBarView.m
//  iSH
//

#import <GameController/GameController.h>
#import "TabBarView.h"
#import "Theme.h"

static const CGFloat kMinStripHeight = 40;
// Width of the leading spacer, the trailing close/hint slot, and the + cell.
static const CGFloat kSlotWidth = 44;
// Below this width per tab the strip stops sharing the width equally and scrolls instead.
static const CGFloat kMinTabWidth = 150;
static const NSTimeInterval kFadeDuration = 0.15;

static UIFont *TabFont(void) {
    return [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:13]];
}

#pragma mark - TabItemView

@interface TabItemView : UIControl
@property (readonly) UILabel *label;
@property (readonly) UILabel *hintLabel;
@property (readonly) UIButton *closeButton;
@property (readonly) UIView *separator;
@property (readonly) UIView *bottomLine;
@property (readonly) NSLayoutConstraint *widthConstraint;
@property NSUUID *sessionUUID;
@property NSUInteger index;
@property BOOL tabSelected;
@property BOOL hovered;
@property BOOL closeVisible;
@property BOOL hintVisible;
@end

@implementation TabItemView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _label = [UILabel new];
        _label.font = TabFont();
        _label.adjustsFontForContentSizeCategory = YES;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        _hintLabel = [UILabel new];
        _hintLabel.font = TabFont();
        _hintLabel.adjustsFontForContentSizeCategory = YES;
        _hintLabel.textAlignment = NSTextAlignmentCenter;
        _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _hintLabel.userInteractionEnabled = NO;
        _hintLabel.isAccessibilityElement = NO;
        [self addSubview:_hintLabel];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark"
                                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightMedium]]
                      forState:UIControlStateNormal];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        _closeButton.pointerInteractionEnabled = YES;
        // Both start hidden, matching closeVisible/hintVisible, until the first update.
        _closeButton.alpha = 0;
        _closeButton.userInteractionEnabled = NO;
        _closeButton.isAccessibilityElement = NO;
        _hintLabel.alpha = 0;
        [self addSubview:_closeButton];

        _separator = [UIView new];
        _separator.translatesAutoresizingMaskIntoConstraints = NO;
        _separator.userInteractionEnabled = NO;
        [self addSubview:_separator];

        _bottomLine = [UIView new];
        _bottomLine.translatesAutoresizingMaskIntoConstraints = NO;
        _bottomLine.userInteractionEnabled = NO;
        [self addSubview:_bottomLine];

        _widthConstraint = [self.widthAnchor constraintEqualToConstant:kMinTabWidth];

        [NSLayoutConstraint activateConstraints:@[
            [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:kSlotWidth],
            [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-kSlotWidth],

            [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_closeButton.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_closeButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_closeButton.widthAnchor constraintEqualToConstant:kSlotWidth],

            [_hintLabel.centerXAnchor constraintEqualToAnchor:_closeButton.centerXAnchor],
            [_hintLabel.centerYAnchor constraintEqualToAnchor:_closeButton.centerYAnchor],

            [_separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_separator.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_separator.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_separator.widthAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale],

            [_bottomLine.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_bottomLine.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_bottomLine.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_bottomLine.heightAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale],
        ]];
    }
    return self;
}

- (void)setCloseVisible:(BOOL)visible hintVisible:(BOOL)hintVisible animated:(BOOL)animated {
    if (visible == self.closeVisible && hintVisible == self.hintVisible)
        return;
    self.closeVisible = visible;
    self.hintVisible = hintVisible;
    // Hidden controls must not be tappable or reachable by assistive technologies.
    self.closeButton.userInteractionEnabled = visible;
    self.closeButton.isAccessibilityElement = visible;
    [UIView animateWithDuration:animated ? kFadeDuration : 0 animations:^{
        self.closeButton.alpha = visible ? 1 : 0;
        self.hintLabel.alpha = hintVisible ? 1 : 0;
    }];
}

@end

#pragma mark - TabScrollView

// Lets a drag that starts on a tab scroll the strip instead of getting stuck on the control.
@interface TabScrollView : UIScrollView
@end

@implementation TabScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}
@end

#pragma mark - TabBarView

@interface TabBarView () <UIContextMenuInteractionDelegate>
@property NSArray<TerminalSession *> *sessions;
@property TabScrollView *scrollView;
@property UIStackView *stack;
@property UIButton *addTabButton;
@property UIButton *commandsButton;
@property UIView *bottomRule;
@property NSLayoutConstraint *heightConstraint;
@property NSLayoutConstraint *fillWidthConstraint;
@property BOOL fillMode;
@property BOOL hardwareKeyboard;
@property UIColor *foreground;
@property UIColor *background;
@property NSUInteger selectedIndex;
@property NSUUID *revealedUUID;
@property CGFloat lastLayoutWidth;
@end

@implementation TabBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.foreground = UIColor.labelColor;
        self.background = UIColor.systemBackgroundColor;
        self.sessions = @[];
        self.selectedIndex = NSNotFound;
        self.fillMode = YES;
        self.accessibilityIdentifier = @"tab bar";

        _bottomRule = [UIView new];
        _bottomRule.translatesAutoresizingMaskIntoConstraints = NO;
        _bottomRule.userInteractionEnabled = NO;
        [self addSubview:_bottomRule];

        _addTabButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_addTabButton setImage:[UIImage systemImageNamed:@"plus"
                                         withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]]
                       forState:UIControlStateNormal];
        _addTabButton.accessibilityLabel = @"New Tab";
        _addTabButton.accessibilityIdentifier = @"new tab";
        _addTabButton.translatesAutoresizingMaskIntoConstraints = NO;
        _addTabButton.pointerInteractionEnabled = YES;
        [_addTabButton addTarget:self action:@selector(newTabPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [self addSubview:_addTabButton];

        // Every command the app has, for people without a keyboard.
        _commandsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_commandsButton setImage:[UIImage systemImageNamed:@"ellipsis"
                                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]]
                         forState:UIControlStateNormal];
        _commandsButton.accessibilityLabel = @"Commands";
        _commandsButton.accessibilityIdentifier = @"commands";
        _commandsButton.translatesAutoresizingMaskIntoConstraints = NO;
        _commandsButton.pointerInteractionEnabled = YES;
        _commandsButton.showsMenuAsPrimaryAction = YES;
        __weak TabBarView *weakSelf = self;
        _commandsButton.menu = [UIMenu menuWithChildren:@[
            [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
                completion([weakSelf.delegate commandsMenuForTabBar:weakSelf].children ?: @[]);
            }],
        ]];
        [self addSubview:_commandsButton];

        _scrollView = [TabScrollView new];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.delaysContentTouches = NO;
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_scrollView];

        _stack = [UIStackView new];
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.distribution = UIStackViewDistributionFillEqually;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scrollView addSubview:_stack];

        UILayoutGuide *content = _scrollView.contentLayoutGuide;
        UILayoutGuide *frameGuide = _scrollView.frameLayoutGuide;
        // The strip color extends under the status bar; the controls sit below the safe area.
        _heightConstraint = [_scrollView.heightAnchor constraintEqualToConstant:kMinStripHeight];
        _fillWidthConstraint = [_stack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor];
        [NSLayoutConstraint activateConstraints:@[
            _heightConstraint,
            _fillWidthConstraint,

            [_bottomRule.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_bottomRule.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_bottomRule.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_bottomRule.heightAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale],

            [_scrollView.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
            [_scrollView.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:_addTabButton.leadingAnchor],

            [_addTabButton.trailingAnchor constraintEqualToAnchor:_commandsButton.leadingAnchor],
            [_addTabButton.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
            [_addTabButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_addTabButton.widthAnchor constraintEqualToConstant:kSlotWidth],

            [_commandsButton.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
            [_commandsButton.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
            [_commandsButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_commandsButton.widthAnchor constraintEqualToConstant:kSlotWidth],

            [_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_stack.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_stack.heightAnchor constraintEqualToAnchor:frameGuide.heightAnchor],
        ]];

        // ⌘1…⌘9 hints only make sense with a hardware keyboard attached.
        self.hardwareKeyboard = GCKeyboard.coalescedKeyboard != nil;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardConnectionChanged:) name:GCKeyboardDidConnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardConnectionChanged:) name:GCKeyboardDidDisconnectNotification object:nil];
        [self updateMetrics];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark Content

- (void)setSessions:(NSArray<TerminalSession *> *)sessions selectedIndex:(NSUInteger)selectedIndex {
    BOOL grew = sessions.count > self.sessions.count;
    self.sessions = [sessions copy];
    self.selectedIndex = selectedIndex;
    // Item views follow their session, so a tap or press in flight on one tab can never
    // land on another one after tabs close or move.
    NSMutableDictionary<NSUUID *, TabItemView *> *existing = [NSMutableDictionary new];
    for (TabItemView *item in self.stack.arrangedSubviews) {
        existing[item.sessionUUID] = item;
        [self.stack removeArrangedSubview:item];
    }
    NSMutableArray<TabItemView *> *items = [NSMutableArray new];
    for (TerminalSession *session in sessions) {
        TabItemView *item = existing[session.uuid];
        if (item != nil) {
            [existing removeObjectForKey:session.uuid];
        } else {
            item = [[TabItemView alloc] initWithFrame:CGRectZero];
            item.sessionUUID = session.uuid;
            [item addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
            [item addTarget:self action:@selector(tabHighlightChanged:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter | UIControlEventTouchDragExit | UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [item.closeButton addTarget:self action:@selector(closePressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
            [item addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(tabHovered:)]];
            [item addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
        }
        [self.stack addArrangedSubview:item];
        [items addObject:item];
    }
    for (TabItemView *gone in existing.allValues)
        [gone removeFromSuperview];
    [sessions enumerateObjectsUsingBlock:^(TerminalSession *session, NSUInteger i, BOOL *stop) {
        TabItemView *item = items[i];
        item.index = i;
        item.tabSelected = i == selectedIndex;
        NSString *title = session.displayTitle;
        if (session.state == TerminalSessionStateExited)
            title = [title stringByAppendingString:@" · exited"];
        item.label.text = title;
        item.hintLabel.text = [NSString stringWithFormat:@"⌘%lu", (unsigned long) i + 1];
        item.accessibilityLabel = title;
        item.accessibilityIdentifier = [NSString stringWithFormat:@"tab %lu", (unsigned long) i + 1];
        item.closeButton.accessibilityLabel = [NSString stringWithFormat:@"Close %@", session.displayTitle];
        item.closeButton.accessibilityIdentifier = [NSString stringWithFormat:@"close tab %lu", (unsigned long) i + 1];
        item.accessibilityTraits = item.tabSelected ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
        item.accessibilityCustomActions = @[
            [[UIAccessibilityCustomAction alloc] initWithName:@"Close" target:self selector:@selector(closeAction:)],
            [[UIAccessibilityCustomAction alloc] initWithName:@"Rename" target:self selector:@selector(renameAction:)],
        ];
    }];
    [self updateLayoutMode];
    [self applyColors];

    // Only pull the strip to the selected tab when the selection changed or a tab was added,
    // so a title change does not yank the user away from the tabs they are browsing.
    NSUUID *selectedUUID = selectedIndex < sessions.count ? sessions[selectedIndex].uuid : nil;
    if (grew || ![selectedUUID isEqual:self.revealedUUID]) {
        self.revealedUUID = selectedUUID;
        [self scrollSelectedTabIntoView];
    }
}

- (NSUInteger)indexOfSessionUUID:(NSUUID *)uuid {
    return [self.sessions indexOfObjectPassingTest:^BOOL(TerminalSession *session, NSUInteger idx, BOOL *stop) {
        return [session.uuid isEqual:uuid];
    }];
}

- (void)setBackgroundColor:(UIColor *)background foregroundColor:(UIColor *)foreground {
    self.background = background;
    self.foreground = foreground;
    [self applyColors];
}

- (void)applyColors {
    // The strip is the terminal background nudged toward the foreground, so it follows the
    // theme's hue and still separates from pure black or pure white. The selected tab is
    // exactly the terminal background, so it connects to the terminal with no seam.
    UIColor *strip = [self.background ish_blendedWithColor:self.foreground fraction:0.07];
    UIColor *hoverStrip = [self.background ish_blendedWithColor:self.foreground fraction:0.12];
    UIColor *rule = [self.foreground colorWithAlphaComponent:0.14];
    UIColor *dimText = [self.foreground colorWithAlphaComponent:0.65];
    UIColor *hintText = [self.foreground colorWithAlphaComponent:0.55];
    self.backgroundColor = strip;
    self.scrollView.backgroundColor = UIColor.clearColor;
    self.bottomRule.backgroundColor = rule;
    self.addTabButton.tintColor = dimText;
    self.commandsButton.tintColor = dimText;
    BOOL showHints = self.hardwareKeyboard && self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
    NSUInteger count = self.stack.arrangedSubviews.count;
    [self.stack.arrangedSubviews enumerateObjectsUsingBlock:^(TabItemView *item, NSUInteger i, BOOL *stop) {
        BOOL active = item.hovered || item.highlighted;
        item.backgroundColor = item.tabSelected ? self.background : active ? hoverStrip : strip;
        item.label.textColor = item.tabSelected ? self.foreground : dimText;
        item.hintLabel.textColor = hintText;
        item.closeButton.tintColor = item.tabSelected ? self.foreground : dimText;
        // Separators sit between inactive tabs; the selected tab's edges stay clean.
        BOOL hideSeparator = i + 1 == count || item.tabSelected || i + 1 == self.selectedIndex;
        item.separator.backgroundColor = hideSeparator ? UIColor.clearColor : rule;
        // Only the selected tab opens onto the terminal; every other tab is closed off below.
        item.bottomLine.backgroundColor = item.tabSelected ? UIColor.clearColor : rule;
        BOOL closeVisible = item.tabSelected || item.hovered;
        [item setCloseVisible:closeVisible hintVisible:!closeVisible && showHints && i < 9 animated:YES];
    }];
}

#pragma mark Layout

- (void)updateMetrics {
    UIFont *font = TabFont();
    self.heightConstraint.constant = MAX(kMinStripHeight, ceil(font.lineHeight) + 16);
    for (TabItemView *item in self.stack.arrangedSubviews) {
        item.label.font = font;
        item.hintLabel.font = font;
    }
    [self updateLayoutMode];
}

- (CGFloat)minimumTabWidth {
    // Give long text sizes room to show more than a couple of letters.
    return UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? kMinTabWidth * 1.5 : kMinTabWidth;
}

// Fill mode: tabs share the strip equally. Scroll mode: fixed-width tabs, strip scrolls.
- (void)updateLayoutMode {
    NSUInteger count = self.stack.arrangedSubviews.count;
    CGFloat available = self.bounds.size.width - self.safeAreaInsets.left - self.safeAreaInsets.right - 2 * kSlotWidth;
    CGFloat minimum = self.minimumTabWidth;
    BOOL fill = count == 0 || available <= 0 || available / count >= minimum;
    BOOL changed = fill != self.fillMode;
    self.fillMode = fill;
    // Deactivate the outgoing set before the incoming one so the two never conflict.
    if (fill) {
        for (TabItemView *item in self.stack.arrangedSubviews)
            item.widthConstraint.active = NO;
        self.fillWidthConstraint.active = YES;
    } else {
        self.fillWidthConstraint.active = NO;
        for (TabItemView *item in self.stack.arrangedSubviews)
            item.widthConstraint.active = NO;
        for (TabItemView *item in self.stack.arrangedSubviews) {
            item.widthConstraint.constant = minimum;
            item.widthConstraint.active = YES;
        }
    }
    if (changed)
        [self setNeedsLayout];
}

- (void)layoutSubviews {
    [self updateLayoutMode];
    [super layoutSubviews];
    // A narrower window can push the selected tab out of view; bring it back.
    CGFloat width = self.bounds.size.width;
    if (width != self.lastLayoutWidth) {
        self.lastLayoutWidth = width;
        [self scrollSelectedTabIntoView];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection] ||
        self.traitCollection.preferredContentSizeCategory != previousTraitCollection.preferredContentSizeCategory ||
        self.traitCollection.horizontalSizeClass != previousTraitCollection.horizontalSizeClass) {
        [self updateMetrics];
        [self applyColors];
        [self scrollSelectedTabIntoView];
    }
}

- (void)scrollSelectedTabIntoView {
    // Resolve the selected item when the block runs: tabs may have closed by then.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.selectedIndex >= self.stack.arrangedSubviews.count)
            return;
        [self layoutIfNeeded];
        UIView *item = self.stack.arrangedSubviews[self.selectedIndex];
        [self.scrollView scrollRectToVisible:[self.scrollView convertRect:item.bounds fromView:item] animated:YES];
    });
}

- (void)keyboardConnectionChanged:(NSNotification *)notif {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hardwareKeyboard = GCKeyboard.coalescedKeyboard != nil;
        [self applyColors];
    });
}

#pragma mark Actions

- (void)tabPressed:(TabItemView *)item {
    [self.delegate tabBar:self didSelectTabAtIndex:item.index];
}

- (void)tabHighlightChanged:(TabItemView *)item {
    [self applyColors];
}

- (void)tabHovered:(UIHoverGestureRecognizer *)recognizer {
    TabItemView *item = (TabItemView *) recognizer.view;
    BOOL hovered = recognizer.state == UIGestureRecognizerStateBegan || recognizer.state == UIGestureRecognizerStateChanged;
    if (hovered == item.hovered)
        return;
    item.hovered = hovered;
    [self applyColors];
}

- (void)closePressed:(UIButton *)button {
    TabItemView *item = (TabItemView *) button.superview;
    [self.delegate tabBar:self didRequestCloseTabAtIndex:item.index];
}

- (TabItemView *)itemForAccessibilityAction:(UIAccessibilityCustomAction *)action {
    for (TabItemView *item in self.stack.arrangedSubviews) {
        if ([item.accessibilityCustomActions containsObject:action])
            return item;
    }
    return nil;
}

- (BOOL)renameAction:(UIAccessibilityCustomAction *)action {
    TabItemView *item = [self itemForAccessibilityAction:action];
    if (item == nil)
        return NO;
    [self.delegate tabBar:self didRequestRenameTabAtIndex:item.index];
    return YES;
}

- (BOOL)closeAction:(UIAccessibilityCustomAction *)action {
    TabItemView *item = [self itemForAccessibilityAction:action];
    if (item == nil)
        return NO;
    [self.delegate tabBar:self didRequestCloseTabAtIndex:item.index];
    return YES;
}

- (void)newTabPressed:(UIButton *)button {
    [self.delegate tabBarDidRequestNewTab:self];
}

#pragma mark Context menu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    TabItemView *item = (TabItemView *) interaction.view;
    // Item views are reused by position, so remember the session, not the index: tabs can
    // close while the menu is open.
    NSUUID *uuid = item.sessionUUID;
    __weak TabBarView *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *action) {
            NSUInteger index = [weakSelf indexOfSessionUUID:uuid];
            if (index != NSNotFound)
                [weakSelf.delegate tabBar:weakSelf didRequestRenameTabAtIndex:index];
        }];
        UIAction *newTab = [UIAction actionWithTitle:@"New Tab" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *action) {
            [weakSelf.delegate tabBarDidRequestNewTab:weakSelf];
        }];
        UIAction *close = [UIAction actionWithTitle:@"Close Tab" image:[UIImage systemImageNamed:@"xmark"] identifier:nil handler:^(UIAction *action) {
            NSUInteger index = [weakSelf indexOfSessionUUID:uuid];
            if (index != NSNotFound)
                [weakSelf.delegate tabBar:weakSelf didRequestCloseTabAtIndex:index];
        }];
        close.attributes = UIMenuElementAttributesDestructive;
        UIAction *closeOthers = [UIAction actionWithTitle:@"Close Other Tabs" image:nil identifier:nil handler:^(UIAction *action) {
            NSUInteger index = [weakSelf indexOfSessionUUID:uuid];
            if (index != NSNotFound)
                [weakSelf.delegate tabBar:weakSelf didRequestCloseOtherTabsAtIndex:index];
        }];
        closeOthers.attributes = UIMenuElementAttributesDestructive;
        if (weakSelf.sessions.count < 2)
            closeOthers.attributes |= UIMenuElementAttributesDisabled;
        return [UIMenu menuWithTitle:@"" children:@[rename, newTab, close, closeOthers]];
    }];
}

@end
