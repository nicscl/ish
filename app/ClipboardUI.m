//
//  ClipboardUI.m
//  iSH
//

#import "ClipboardUI.h"

#pragma mark - Helpers

void ClipSetCornerRadius(UIView *view, CGFloat radius) {
    if (@available(iOS 26, *)) {
        view.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:radius]];
    } else {
        view.layer.cornerRadius = radius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.clipsToBounds = YES;
    }
}

UIVisualEffectView *ClipGlassView(CGFloat cornerRadius) {
    UIVisualEffectView *view;
    if (@available(iOS 26, *)) {
        view = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
    } else {
        view = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    }
    ClipSetCornerRadius(view, cornerRadius);
    return view;
}

NSString *ClipShortRelativeTime(NSDate *date) {
    NSTimeInterval age = -date.timeIntervalSinceNow;
    if (age < 60)
        return @"now";
    if (age < 3600)
        return [NSString stringWithFormat:@"%.0fm", floor(age / 60)];
    if (age < 86400)
        return [NSString stringWithFormat:@"%.0fh", floor(age / 3600)];
    if (age < 7 * 86400)
        return [NSString stringWithFormat:@"%.0fd", floor(age / 86400)];
    if (age < 60 * 86400)
        return [NSString stringWithFormat:@"%.0fw", floor(age / (7 * 86400))];
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
    });
    return [formatter stringFromDate:date];
}

CGFloat ClipCardSide(ClipCardSize size, UITraitCollection *traits) {
    BOOL compactWidth = traits.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    switch (size) {
        case ClipCardSizeCompact: return compactWidth ? 112 : 132;
        case ClipCardSizeRegular: return compactWidth ? 144 : 176;
        case ClipCardSizeLarge: return compactWidth ? 188 : 232;
    }
    return 176;
}

void ClipShowToast(UIView *view, NSString *text, NSString *symbol) {
    UIVisualEffectView *toast = ClipGlassView(20);
    toast.userInteractionEnabled = NO;
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *row = [UIStackView new];
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    if (symbol != nil) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        icon.tintColor = UIColor.labelColor;
        [row addArrangedSubview:icon];
    }
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [row addArrangedSubview:label];
    [toast.contentView addSubview:row];
    [view addSubview:toast];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:toast.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:toast.contentView.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:toast.contentView.topAnchor constant:10],
        [row.bottomAnchor constraintEqualToAnchor:toast.contentView.bottomAnchor constant:-10],
        [toast.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [toast.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:56],
    ]];
    toast.accessibilityLabel = text;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    toast.alpha = 0;
    toast.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.2 animations:^{
        toast.alpha = 1;
        toast.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{
            toast.alpha = 0;
        } completion:^(BOOL done) {
            [toast removeFromSuperview];
        }];
    }];
}

static UIColor *CardBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.17 alpha:1] : UIColor.whiteColor;
    }];
}

static UIColor *SourceColor(ClipSource source) {
    switch (source) {
        case ClipSourceOtherApp: return UIColor.systemBlueColor;
        case ClipSourceTerminal: return UIColor.systemGreenColor;
        case ClipSourceLinux: return UIColor.systemOrangeColor;
        case ClipSourceCreated: return UIColor.systemPurpleColor;
    }
    return UIColor.systemGrayColor;
}

static BOOL ColorIsLight(UIColor *color) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a])
        return YES;
    return (0.299 * r + 0.587 * g + 0.114 * b) * a + (1 - a) > 0.6;
}

#pragma mark - ClipCardCell

typedef NS_ENUM(NSInteger, CardStyle) {
    CardStylePlain,
    CardStyleCode,
    CardStyleColor,
    CardStyleImage,
    CardStyleLink,
    CardStyleFile,
};

@interface ClipCardCell ()
@property UIView *card;
@property UIView *ring;
@property UIImageView *imageView;
@property CAGradientLayer *scrim;
@property UILabel *kindLabel;
@property UILabel *timeLabel;
@property UIView *pinDot;
@property UIView *sourceBadge;
@property UIImageView *sourceIcon;
@property UILabel *bodyLabel;
@property UIImageView *bigIcon;
@property UIView *linkFooter;
@property UILabel *linkTitleLabel;
@property UILabel *linkDomainLabel;
@property UILabel *footerLabel;
@property UILabel *sizeBadge;
@property UILabel *shortcutBadge;
@property CardStyle style;
@end

@implementation ClipCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _ring = [UIView new];
        _ring.userInteractionEnabled = NO;
        _ring.layer.borderWidth = 3;
        _ring.layer.cornerCurve = kCACornerCurveContinuous;
        _ring.hidden = YES;
        [self.contentView addSubview:_ring];

        _card = [UIView new];
        _card.layer.cornerRadius = 16;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.clipsToBounds = YES;
        [self.contentView addSubview:_card];
        self.contentView.layer.shadowColor = UIColor.blackColor.CGColor;
        self.contentView.layer.shadowOpacity = 0.12;
        self.contentView.layer.shadowRadius = 6;
        self.contentView.layer.shadowOffset = CGSizeMake(0, 2);

        _imageView = [UIImageView new];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [_card addSubview:_imageView];

        _scrim = [CAGradientLayer layer];
        _scrim.colors = @[(id) [UIColor colorWithWhite:0 alpha:0.45].CGColor, (id) [UIColor colorWithWhite:0 alpha:0].CGColor];
        [_card.layer addSublayer:_scrim];

        _bigIcon = [UIImageView new];
        _bigIcon.contentMode = UIViewContentModeScaleAspectFit;
        _bigIcon.tintColor = UIColor.secondaryLabelColor;
        [_card addSubview:_bigIcon];

        _bodyLabel = [UILabel new];
        _bodyLabel.numberOfLines = 0;
        _bodyLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_bodyLabel];

        _kindLabel = [UILabel new];
        _timeLabel = [UILabel new];
        [_card addSubview:_kindLabel];
        [_card addSubview:_timeLabel];

        _pinDot = [UIView new];
        _pinDot.layer.cornerRadius = 4;
        [_card addSubview:_pinDot];

        _sourceBadge = [UIView new];
        _sourceBadge.layer.cornerRadius = 5;
        _sourceBadge.layer.cornerCurve = kCACornerCurveContinuous;
        _sourceIcon = [UIImageView new];
        _sourceIcon.tintColor = UIColor.whiteColor;
        _sourceIcon.contentMode = UIViewContentModeCenter;
        [_sourceBadge addSubview:_sourceIcon];
        [_card addSubview:_sourceBadge];

        _linkFooter = [UIView new];
        _linkFooter.backgroundColor = CardBackground();
        _linkTitleLabel = [UILabel new];
        _linkTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _linkDomainLabel = [UILabel new];
        _linkDomainLabel.textColor = UIColor.secondaryLabelColor;
        _linkDomainLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_linkFooter addSubview:_linkTitleLabel];
        [_linkFooter addSubview:_linkDomainLabel];
        [_card addSubview:_linkFooter];

        _footerLabel = [UILabel new];
        _footerLabel.textAlignment = NSTextAlignmentCenter;
        [_card addSubview:_footerLabel];

        _sizeBadge = [UILabel new];
        _sizeBadge.textAlignment = NSTextAlignmentCenter;
        _sizeBadge.textColor = UIColor.whiteColor;
        _sizeBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        _sizeBadge.clipsToBounds = YES;
        [_card addSubview:_sizeBadge];

        _shortcutBadge = [UILabel new];
        _shortcutBadge.textAlignment = NSTextAlignmentCenter;
        _shortcutBadge.textColor = UIColor.whiteColor;
        _shortcutBadge.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.75];
        _shortcutBadge.clipsToBounds = YES;
        _shortcutBadge.hidden = YES;
        [_card addSubview:_shortcutBadge];

        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (CGFloat)scale {
    return MAX(0.75, MIN(1.3, self.bounds.size.width / 176));
}

- (void)configureWithItem:(ClipItem *)item pinboard:(ClipPinboard *)pinboard {
    CGFloat s = self.scale;
    UIColor *background = CardBackground();
    UIColor *foreground = UIColor.labelColor;
    UIColor *secondary = UIColor.secondaryLabelColor;
    UIImage *thumbnail = item.thumbnail;

    switch (item.kind) {
        case ClipKindText: self.style = item.looksLikeCode ? CardStyleCode : CardStylePlain; break;
        case ClipKindColor: self.style = CardStyleColor; break;
        case ClipKindImage: self.style = CardStyleImage; break;
        case ClipKindLink: self.style = CardStyleLink; break;
        case ClipKindFile: self.style = CardStyleFile; break;
    }
    if (self.style == CardStyleCode) {
        background = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1];
        foreground = [UIColor colorWithWhite:0.92 alpha:1];
        secondary = [UIColor colorWithWhite:0.6 alpha:1];
    } else if (self.style == CardStyleColor) {
        background = item.color ?: UIColor.grayColor;
        BOOL light = ColorIsLight(background);
        foreground = light ? UIColor.blackColor : UIColor.whiteColor;
        secondary = [foreground colorWithAlphaComponent:0.65];
    }
    BOOL overImage = (self.style == CardStyleImage || self.style == CardStyleLink) && thumbnail != nil;
    self.card.backgroundColor = self.style == CardStyleColor || self.style == CardStyleCode ? background : CardBackground();

    self.kindLabel.text = item.title.length > 0 && item.kind != ClipKindText ? item.title : ClipKindName(item.kind);
    self.kindLabel.font = [UIFont systemFontOfSize:11 * s weight:UIFontWeightSemibold];
    self.kindLabel.textColor = overImage ? UIColor.whiteColor : foreground;
    self.timeLabel.text = ClipShortRelativeTime(item.copiedAt);
    self.timeLabel.font = [UIFont systemFontOfSize:11 * s];
    self.timeLabel.textColor = overImage ? [UIColor colorWithWhite:1 alpha:0.8] : secondary;
    self.scrim.hidden = !overImage;

    self.pinDot.hidden = pinboard == nil;
    self.pinDot.backgroundColor = pinboard.color;

    self.sourceBadge.backgroundColor = SourceColor(item.source);
    self.sourceIcon.image = [UIImage systemImageNamed:ClipSourceSymbol(item.source)
                                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 * s weight:UIImageSymbolWeightBold]];

    self.imageView.hidden = !overImage;
    self.imageView.image = overImage ? thumbnail : nil;
    self.imageView.backgroundColor = UIColor.tertiarySystemFillColor;
    self.bigIcon.hidden = YES;
    self.linkFooter.hidden = self.style != CardStyleLink;
    self.sizeBadge.hidden = YES;
    self.footerLabel.hidden = YES;
    self.bodyLabel.hidden = NO;
    self.bodyLabel.textAlignment = NSTextAlignmentNatural;
    self.bodyLabel.attributedText = nil;

    NSString *text = item.text ?: @"";
    if (text.length > 1200)
        text = [text substringToIndex:1200];
    switch (self.style) {
        case CardStylePlain: {
            // A short first line reads as a heading, as in Paste.
            NSMutableAttributedString *body = [NSMutableAttributedString new];
            UIFont *font = [UIFont systemFontOfSize:12.5 * s];
            NSRange newline = [text rangeOfString:@"\n"];
            NSString *title = item.title;
            if (title.length > 0) {
                [body appendAttributedString:[[NSAttributedString alloc] initWithString:[title stringByAppendingString:@"\n"]
                    attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 * s weight:UIFontWeightSemibold], NSForegroundColorAttributeName: foreground}]];
            } else if (newline.location != NSNotFound && newline.location > 0 && newline.location <= 40) {
                [body appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringToIndex:newline.location + 1]
                    attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 * s weight:UIFontWeightSemibold], NSForegroundColorAttributeName: foreground}]];
                text = [text substringFromIndex:newline.location + 1];
            }
            [body appendAttributedString:[[NSAttributedString alloc] initWithString:text
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: foreground}]];
            self.bodyLabel.attributedText = body;
            self.footerLabel.hidden = NO;
            break;
        }
        case CardStyleCode:
            self.bodyLabel.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:10.5 * s weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: foreground}];
            self.footerLabel.hidden = NO;
            break;
        case CardStyleColor:
            self.bodyLabel.text = text.uppercaseString;
            self.bodyLabel.font = [UIFont monospacedSystemFontOfSize:14 * s weight:UIFontWeightMedium];
            self.bodyLabel.textColor = foreground;
            self.bodyLabel.textAlignment = NSTextAlignmentCenter;
            break;
        case CardStyleImage:
            self.bodyLabel.hidden = YES;
            if (!overImage) {
                self.bigIcon.hidden = NO;
                self.bigIcon.image = [UIImage systemImageNamed:@"photo"];
            }
            self.sizeBadge.hidden = item.footnote == nil;
            self.sizeBadge.text = item.footnote;
            self.sizeBadge.font = [UIFont monospacedDigitSystemFontOfSize:10 * s weight:UIFontWeightMedium];
            break;
        case CardStyleLink:
            self.bodyLabel.hidden = overImage;
            self.bodyLabel.text = text;
            self.bodyLabel.font = [UIFont systemFontOfSize:12 * s];
            self.bodyLabel.textColor = UIColor.linkColor;
            self.linkTitleLabel.text = item.linkTitle ?: item.displayTitle;
            self.linkTitleLabel.font = [UIFont systemFontOfSize:12.5 * s weight:UIFontWeightSemibold];
            self.linkDomainLabel.text = item.footnote;
            self.linkDomainLabel.font = [UIFont systemFontOfSize:10.5 * s];
            break;
        case CardStyleFile: {
            self.bigIcon.hidden = NO;
            NSArray<NSString *> *paths = [text componentsSeparatedByString:@"\n"];
            self.bigIcon.image = [UIImage systemImageNamed:paths.count > 1 ? @"doc.on.doc.fill" : @"doc.fill"];
            self.bodyLabel.text = paths.count > 1 ? [NSString stringWithFormat:@"%lu files", (unsigned long) paths.count] : text;
            self.bodyLabel.font = [UIFont systemFontOfSize:10.5 * s];
            self.bodyLabel.textColor = secondary;
            self.bodyLabel.textAlignment = NSTextAlignmentCenter;
            self.bodyLabel.lineBreakMode = NSLineBreakByTruncatingHead;
            break;
        }
    }
    if (self.style != CardStyleFile)
        self.bodyLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.footerLabel.text = item.footnote;
    self.footerLabel.font = [UIFont systemFontOfSize:10 * s];
    self.footerLabel.textColor = secondary;
    self.footerLabel.backgroundColor = self.card.backgroundColor;

    self.shortcutBadge.font = [UIFont systemFontOfSize:11 * s weight:UIFontWeightSemibold];

    NSMutableArray<NSString *> *spoken = [NSMutableArray arrayWithObject:ClipKindName(item.kind)];
    if (pinboard != nil)
        [spoken addObject:[@"pinned to " stringByAppendingString:pinboard.name]];
    [spoken addObject:item.displayTitle];
    if (item.footnote)
        [spoken addObject:item.footnote];
    self.accessibilityLabel = [spoken componentsJoinedByString:@", "];
    self.accessibilityValue = ClipShortRelativeTime(item.copiedAt);
    [self setNeedsLayout];
}

- (void)setCardSelected:(BOOL)cardSelected {
    _cardSelected = cardSelected;
    self.ring.hidden = !cardSelected;
    self.ring.layer.borderColor = self.tintColor.CGColor;
    if (cardSelected)
        self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else
        self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    self.ring.layer.borderColor = self.tintColor.CGColor;
}

- (void)setShortcutNumber:(NSInteger)shortcutNumber {
    _shortcutNumber = shortcutNumber;
    self.shortcutBadge.hidden = shortcutNumber <= 0;
    self.shortcutBadge.text = [NSString stringWithFormat:@"⌘%ld", (long) shortcutNumber];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.ring.layer.borderColor = self.tintColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat s = self.scale;
    self.card.frame = bounds;
    self.ring.frame = CGRectInset(bounds, -5, -5);
    self.ring.layer.cornerRadius = 21;
    self.contentView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:16].CGPath;

    CGFloat pad = 10 * s;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    CGFloat headerHeight = 16 * s;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.scrim.frame = CGRectMake(0, 0, w, 44 * s);
    [CATransaction commit];

    CGFloat badgeSide = 16 * s;
    self.sourceBadge.frame = CGRectMake(w - pad - badgeSide, pad - 1, badgeSide, badgeSide);
    self.sourceIcon.frame = self.sourceBadge.bounds;

    CGFloat x = pad;
    if (!self.pinDot.hidden) {
        self.pinDot.frame = CGRectMake(x, pad + (headerHeight - 8) / 2, 8, 8);
        x += 12;
    }
    CGSize kindSize = [self.kindLabel sizeThatFits:CGSizeMake(w, headerHeight)];
    CGFloat maxKind = w - x - pad - badgeSide - 34 * s;
    self.kindLabel.frame = CGRectMake(x, pad, MIN(kindSize.width, maxKind), headerHeight);
    CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(w, headerHeight)];
    self.timeLabel.frame = CGRectMake(CGRectGetMaxX(self.kindLabel.frame) + 5, pad, timeSize.width, headerHeight);

    CGFloat top = pad + headerHeight + 6 * s;
    CGFloat footerHeight = 14 * s;
    self.footerLabel.frame = CGRectMake(pad, h - pad - footerHeight + 2, w - 2 * pad, footerHeight);

    switch (self.style) {
        case CardStylePlain:
        case CardStyleCode:
            self.bodyLabel.frame = CGRectMake(pad, top, w - 2 * pad, h - top - pad - footerHeight - 4 * s);
            [self fitBodyLabelToTop];
            break;
        case CardStyleColor:
            self.bodyLabel.frame = CGRectMake(pad, top, w - 2 * pad, h - top - pad - headerHeight);
            break;
        case CardStyleImage:
            self.imageView.frame = bounds;
            self.bigIcon.frame = CGRectMake(w / 2 - 22 * s, h / 2 - 22 * s, 44 * s, 44 * s);
            [self layoutBadge:self.sizeBadge bottom:h - pad];
            break;
        case CardStyleLink: {
            CGFloat footer = 44 * s;
            self.linkFooter.frame = CGRectMake(0, h - footer, w, footer);
            self.linkTitleLabel.frame = CGRectMake(pad, 6 * s, w - 2 * pad, 17 * s);
            self.linkDomainLabel.frame = CGRectMake(pad, 23 * s, w - 2 * pad, 14 * s);
            self.imageView.frame = CGRectMake(0, 0, w, h - footer);
            self.bodyLabel.frame = CGRectMake(pad, top, w - 2 * pad, h - footer - top - 6 * s);
            [self fitBodyLabelToTop];
            break;
        }
        case CardStyleFile: {
            CGFloat icon = 44 * s;
            self.bigIcon.frame = CGRectMake((w - icon) / 2, top + (h - top - icon - 40 * s) / 2, icon, icon);
            self.bodyLabel.numberOfLines = 2;
            self.bodyLabel.frame = CGRectMake(pad, h - pad - 30 * s, w - 2 * pad, 30 * s);
            break;
        }
    }
    if (self.style != CardStyleFile)
        self.bodyLabel.numberOfLines = 0;
    if (!self.shortcutBadge.hidden)
        [self layoutBadge:self.shortcutBadge bottom:self.style == CardStyleLink ? h - 44 * s - 6 : h - pad];
}

// A label with numberOfLines 0 centers vertically; cards read from the top.
- (void)fitBodyLabelToTop {
    CGRect frame = self.bodyLabel.frame;
    CGSize fit = [self.bodyLabel sizeThatFits:CGSizeMake(frame.size.width, CGFLOAT_MAX)];
    frame.size.height = MIN(frame.size.height, fit.height);
    // Whole lines only, so the last one is not cut through the middle.
    UIFont *font = self.bodyLabel.font;
    if (self.bodyLabel.attributedText.length > 0)
        font = [self.bodyLabel.attributedText attribute:NSFontAttributeName atIndex:self.bodyLabel.attributedText.length - 1 effectiveRange:NULL] ?: font;
    CGFloat line = font.lineHeight;
    if (line > 0 && fit.height > frame.size.height)
        frame.size.height = floor(frame.size.height / line) * line;
    self.bodyLabel.frame = frame;
}

- (void)layoutBadge:(UILabel *)badge bottom:(CGFloat)bottom {
    CGSize size = [badge sizeThatFits:CGSizeMake(200, 30)];
    size.width += 12;
    size.height += 4;
    badge.frame = CGRectMake((self.bounds.size.width - size.width) / 2, bottom - size.height, size.width, size.height);
    badge.layer.cornerRadius = size.height / 2;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.cardSelected = NO;
    self.shortcutNumber = 0;
}

@end

#pragma mark - ClipTabCell

static UIFont *TabFont(void) {
    return [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
}

@interface ClipTabCell ()
@property UIView *capsule;
@property UIView *dot;
@property UIImageView *icon;
@property UILabel *label;
@end

@implementation ClipTabCell

+ (CGSize)sizeForTitle:(NSString *)title hasIcon:(BOOL)hasIcon {
    CGSize text = [title sizeWithAttributes:@{NSFontAttributeName: TabFont()}];
    return CGSizeMake(ceil(text.width) + 24 + (hasIcon ? 18 : 0), 30);
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _capsule = [UIView new];
        _capsule.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_capsule];
        _dot = [UIView new];
        _dot.layer.cornerRadius = 4.5;
        [self.contentView addSubview:_dot];
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.tintColor = UIColor.labelColor;
        [self.contentView addSubview:_icon];
        _label = [UILabel new];
        _label.font = TabFont();
        _label.textColor = UIColor.labelColor;
        [self.contentView addSubview:_label];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        if (@available(iOS 13.4, *)) {
            [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:nil]];
        }
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title color:(UIColor *)color symbol:(NSString *)symbol {
    self.label.text = title;
    self.dot.hidden = color == nil;
    self.dot.backgroundColor = color;
    self.icon.hidden = symbol == nil;
    self.icon.image = symbol ? [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]] : nil;
    self.accessibilityLabel = title;
    self.accessibilityIdentifier = [@"pinboard " stringByAppendingString:title];
    [self setNeedsLayout];
}

- (void)setTabSelected:(BOOL)tabSelected {
    _tabSelected = tabSelected;
    [self updateCapsule];
    if (tabSelected)
        self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else
        self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
}

- (void)setDropTarget:(BOOL)dropTarget {
    _dropTarget = dropTarget;
    [self updateCapsule];
}

- (void)updateCapsule {
    if (self.dropTarget) {
        self.capsule.backgroundColor = [self.tintColor colorWithAlphaComponent:0.25];
        self.capsule.layer.borderColor = self.tintColor.CGColor;
        self.capsule.layer.borderWidth = 1.5;
    } else {
        self.capsule.backgroundColor = self.tabSelected ? [UIColor.labelColor colorWithAlphaComponent:0.12] : UIColor.clearColor;
        self.capsule.layer.borderWidth = 0;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.capsule.frame = bounds;
    self.capsule.layer.cornerRadius = bounds.size.height / 2;
    CGFloat x = 12;
    if (!self.dot.hidden || !self.icon.hidden) {
        self.dot.frame = CGRectMake(x + 2, (bounds.size.height - 9) / 2, 9, 9);
        self.icon.frame = CGRectMake(x - 2, 0, 18, bounds.size.height);
        x += 18;
    }
    self.label.frame = CGRectMake(x, 0, bounds.size.width - x - 12, bounds.size.height);
}

@end
