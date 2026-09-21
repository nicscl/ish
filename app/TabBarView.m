//
//  TabBarView.m
//  iSH
//

#import "TabBarView.h"

static const CGFloat kTabHeight = 36;
static const CGFloat kButtonWidth = 36;
static const CGFloat kTabMaxWidth = 200;

@interface TabItemView : UIControl
@property (readonly) UILabel *label;
@property (readonly) UIButton *closeButton;
@property NSUInteger index;
@end

@implementation TabItemView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _label = [UILabel new];
        _label.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:13]];
        _label.adjustsFontForContentSizeCategory = YES;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        _closeButton.accessibilityLabel = @"Close Tab";
        [self addSubview:_closeButton];

        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_closeButton.leadingAnchor constraintEqualToAnchor:_label.trailingAnchor constant:4],
            [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_closeButton.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_closeButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_closeButton.widthAnchor constraintEqualToConstant:kButtonWidth],
            [self.widthAnchor constraintLessThanOrEqualToConstant:kTabMaxWidth],
        ]];
        self.layer.cornerRadius = 6;
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    return self;
}

@end

@interface TabBarView ()
@property UIScrollView *scrollView;
@property UIStackView *stack;
@property UIButton *addTabButton;
@property UIColor *foreground;
@property UIColor *background;
@property NSUInteger selectedIndex;
@end

@implementation TabBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.foreground = UIColor.labelColor;
        self.background = UIColor.systemBackgroundColor;
        self.accessibilityIdentifier = @"tab bar";

        _addTabButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_addTabButton setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
        _addTabButton.accessibilityLabel = @"New Tab";
        _addTabButton.accessibilityIdentifier = @"new tab";
        _addTabButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_addTabButton addTarget:self action:@selector(newTabPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [self addSubview:_addTabButton];

        _scrollView = [UIScrollView new];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_scrollView];

        _stack = [UIStackView new];
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scrollView addSubview:_stack];

        UILayoutGuide *content = _scrollView.contentLayoutGuide;
        UILayoutGuide *frameGuide = _scrollView.frameLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:kTabHeight + 8],

            [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [_scrollView.trailingAnchor constraintEqualToAnchor:_addTabButton.leadingAnchor constant:-4],

            [_addTabButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_addTabButton.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
            [_addTabButton.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor],
            [_addTabButton.widthAnchor constraintEqualToConstant:kButtonWidth + 8],

            [_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_stack.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_stack.heightAnchor constraintEqualToAnchor:frameGuide.heightAnchor],
        ]];
    }
    return self;
}

- (void)setSessions:(NSArray<TerminalSession *> *)sessions selectedIndex:(NSUInteger)selectedIndex {
    self.selectedIndex = selectedIndex;
    // Reuse existing item views where possible so taps in flight keep working.
    while (self.stack.arrangedSubviews.count > sessions.count) {
        UIView *extra = self.stack.arrangedSubviews.lastObject;
        [self.stack removeArrangedSubview:extra];
        [extra removeFromSuperview];
    }
    while (self.stack.arrangedSubviews.count < sessions.count) {
        TabItemView *item = [[TabItemView alloc] initWithFrame:CGRectZero];
        [item addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
        [item.closeButton addTarget:self action:@selector(closePressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tabLongPressed:)];
        [item addGestureRecognizer:longPress];
        [self.stack addArrangedSubview:item];
    }
    [sessions enumerateObjectsUsingBlock:^(TerminalSession *session, NSUInteger i, BOOL *stop) {
        TabItemView *item = (TabItemView *) self.stack.arrangedSubviews[i];
        item.index = i;
        NSString *title = session.displayTitle;
        if (session.state == TerminalSessionStateExited)
            title = [title stringByAppendingString:@" (exited)"];
        item.label.text = title;
        item.accessibilityLabel = title;
        item.accessibilityIdentifier = [NSString stringWithFormat:@"tab %lu", (unsigned long) i + 1];
        item.closeButton.accessibilityLabel = [NSString stringWithFormat:@"Close %@", session.displayTitle];
        item.closeButton.accessibilityIdentifier = [NSString stringWithFormat:@"close tab %lu", (unsigned long) i + 1];
        item.accessibilityTraits = i == selectedIndex ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
        item.accessibilityCustomActions = @[
            [[UIAccessibilityCustomAction alloc] initWithName:@"Rename" target:self selector:@selector(renameAction:)],
        ];
    }];
    [self applyColors];
    [self scrollSelectedTabIntoView];
}

- (void)setBackgroundColor:(UIColor *)background foregroundColor:(UIColor *)foreground {
    self.background = background;
    self.foreground = foreground;
    [self applyColors];
}

- (void)applyColors {
    self.backgroundColor = self.background;
    UIColor *selectedBackground = [self.foreground colorWithAlphaComponent:0.18];
    UIColor *dimText = [self.foreground colorWithAlphaComponent:0.6];
    self.addTabButton.tintColor = self.foreground;
    [self.stack.arrangedSubviews enumerateObjectsUsingBlock:^(TabItemView *item, NSUInteger i, BOOL *stop) {
        BOOL selected = i == self.selectedIndex;
        item.backgroundColor = selected ? selectedBackground : UIColor.clearColor;
        item.label.textColor = selected ? self.foreground : dimText;
        item.closeButton.tintColor = selected ? self.foreground : dimText;
    }];
}

- (void)scrollSelectedTabIntoView {
    if (self.selectedIndex >= self.stack.arrangedSubviews.count)
        return;
    UIView *item = self.stack.arrangedSubviews[self.selectedIndex];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.scrollView scrollRectToVisible:[self.scrollView convertRect:item.bounds fromView:item] animated:YES];
    });
}

#pragma mark Actions

- (void)tabPressed:(TabItemView *)item {
    [self.delegate tabBar:self didSelectTabAtIndex:item.index];
}

- (void)closePressed:(UIButton *)button {
    TabItemView *item = (TabItemView *) button.superview;
    [self.delegate tabBar:self didRequestCloseTabAtIndex:item.index];
}

- (void)tabLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan)
        return;
    TabItemView *item = (TabItemView *) recognizer.view;
    [self.delegate tabBar:self didRequestRenameTabAtIndex:item.index];
}

- (BOOL)renameAction:(UIAccessibilityCustomAction *)action {
    for (TabItemView *item in self.stack.arrangedSubviews) {
        if ([item.accessibilityCustomActions containsObject:action]) {
            [self.delegate tabBar:self didRequestRenameTabAtIndex:item.index];
            return YES;
        }
    }
    return NO;
}

- (void)newTabPressed:(UIButton *)button {
    [self.delegate tabBarDidRequestNewTab:self];
}

@end
