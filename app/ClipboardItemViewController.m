//
//  ClipboardItemViewController.m
//  iSH
//

#import <CoreImage/CoreImage.h>
#import <LinkPresentation/LinkPresentation.h>
#import <Vision/Vision.h>
#import "ClipboardItemViewController.h"
#import "ClipboardUI.h"
#import "UIApplication+OpenURL.h"

typedef NS_ENUM(NSInteger, PageMode) {
    PageModePreview,
    PageModeEdit,
    PageModeCreate,
};

static UIImage *RotatedImage(UIImage *image, BOOL clockwise) {
    CGSize size = CGSizeMake(image.size.height, image.size.width);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextTranslateCTM(c, size.width / 2, size.height / 2);
        CGContextRotateCTM(c, clockwise ? M_PI_2 : -M_PI_2);
        [image drawInRect:CGRectMake(-image.size.width / 2, -image.size.height / 2, image.size.width, image.size.height)];
    }];
}

// Redraws the image upright, so Vision and CGImage agree about orientation.
static UIImage *UprightImage(UIImage *image) {
    if (image.imageOrientation == UIImageOrientationUp)
        return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawAtPoint:CGPointZero];
    }];
}

static UIImage *ImageWithoutBackground(UIImage *image, NSError **error) API_AVAILABLE(ios(17.0)) {
    UIImage *upright = UprightImage(image);
    VNGenerateForegroundInstanceMaskRequest *request = [VNGenerateForegroundInstanceMaskRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:upright.CGImage options:@{}];
    if (![handler performRequests:@[request] error:error])
        return nil;
    VNInstanceMaskObservation *observation = request.results.firstObject;
    if (observation == nil)
        return nil;
    CVPixelBufferRef buffer = [observation generateMaskedImageOfInstances:observation.allInstances fromRequestHandler:handler
                                                  croppedToInstancesExtent:YES error:error];
    if (buffer == NULL)
        return nil;
    CIImage *masked = [CIImage imageWithCVPixelBuffer:buffer];
    CGImageRef cg = [[CIContext context] createCGImage:masked fromRect:masked.extent];
    if (cg == NULL)
        return nil;
    UIImage *result = [UIImage imageWithCGImage:cg scale:upright.scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return result;
}

static NSString *ColorDescription(UIColor *color, NSString *hex) {
    CGFloat r, g, b, a, h, s, v;
    [color getRed:&r green:&g blue:&b alpha:&a];
    [color getHue:&h saturation:&s brightness:&v alpha:&a];
    return [NSString stringWithFormat:@"%@\nrgb(%.0f, %.0f, %.0f)%@\nhsb(%.0f°, %.0f%%, %.0f%%)",
            hex.uppercaseString, r * 255, g * 255, b * 255, a < 1 ? [NSString stringWithFormat:@" · %.0f%% opacity", a * 100] : @"",
            h * 360, s * 100, v * 100];
}

#pragma mark - Page

@interface ClipboardItemViewController ()
@property BOOL startedInEditMode;
@end

@interface ClipItemPage : UIViewController <UIScrollViewDelegate, UITextViewDelegate>
@property PageMode mode;
@property NSArray<ClipItem *> *items;
@property NSUInteger index;
@property (nullable) ClipPinboard *pinboard; // for new items
@property (weak) ClipboardItemViewController *owner;

@property UIView *contentHost;
@property (nullable) UITextView *textView;
@property (nullable) UIScrollView *zoomView;
@property (nullable) UIImageView *imageView;
@property (nullable) UIImage *editedImage;
@property (nullable) UIImage *originalImage;
@property (nullable) UIColorWell *colorWell API_AVAILABLE(ios(14.0));
@property (nullable) UIView *swatch;
@property (nullable) UILabel *colorLabel;
@property BOOL dirty;
@end

@implementation ClipItemPage

- (ClipItem *)item {
    return self.index < self.items.count ? self.items[self.index] : nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.contentHost = [UIView new];
    self.contentHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentHost];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.contentHost.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.contentHost.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.contentHost.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.contentHost.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
    [self rebuild];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.mode != PageModePreview && self.textView != nil)
        [self.textView becomeFirstResponder];
    else
        [self becomeFirstResponder];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

#pragma mark Building

- (void)rebuild {
    for (UIView *view in self.contentHost.subviews)
        [view removeFromSuperview];
    self.textView = nil;
    self.zoomView = nil;
    self.imageView = nil;
    self.swatch = nil;
    self.colorLabel = nil;
    if (@available(iOS 14, *))
        self.colorWell = nil;
    self.toolbarItems = nil;
    ClipItem *item = self.item;

    if (self.mode == PageModeCreate) {
        self.title = @"New Text Item";
        [self buildTextViewWithText:@"" attributed:nil code:NO editable:YES];
        [self setUpEditingBar];
        return;
    }
    self.title = item.displayTitle;
    if (@available(iOS 26, *)) {
        NSString *where = item.pinboardID ? [ClipboardStore.shared pinboardWithID:item.pinboardID].name : nil;
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:ClipKindName(item.kind)];
        [parts addObject:ClipShortRelativeTime(item.copiedAt)];
        [parts addObject:item.sourceDetail ?: ClipSourceName(item.source)];
        if (where)
            [parts addObject:where];
        if (self.mode == PageModePreview && self.items.count > 1)
            [parts addObject:[NSString stringWithFormat:@"%lu of %lu", (unsigned long) self.index + 1, (unsigned long) self.items.count]];
        self.navigationItem.subtitle = [parts componentsJoinedByString:@" · "];
    }
    BOOL editing = self.mode == PageModeEdit;
    switch (item.kind) {
        case ClipKindText:
            [self buildTextViewWithText:item.text ?: @"" attributed:item.hasRichText ? [item loadAttributedText] : nil
                                   code:item.looksLikeCode editable:editing];
            break;
        case ClipKindLink:
            if (editing)
                [self buildTextViewWithText:item.text ?: @"" attributed:nil code:NO editable:YES];
            else
                [self buildLinkView:item];
            break;
        case ClipKindImage:
            [self buildImageView:[item loadImage]];
            break;
        case ClipKindColor:
            [self buildColorView:item editable:editing];
            break;
        case ClipKindFile:
            [self buildTextViewWithText:item.text ?: @"" attributed:nil code:YES editable:NO];
            break;
    }
    if (editing)
        [self setUpEditingBar];
    else
        [self setUpPreviewBar];
}

- (void)pin:(UIView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentHost addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:self.contentHost.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:self.contentHost.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:self.contentHost.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:self.contentHost.bottomAnchor],
    ]];
}

- (void)buildTextViewWithText:(NSString *)text attributed:(NSAttributedString *)attributed code:(BOOL)code editable:(BOOL)editable {
    UITextView *textView = [UITextView new];
    textView.editable = editable;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.textContainerInset = UIEdgeInsetsMake(20, 16, 20, 16);
    textView.backgroundColor = UIColor.clearColor;
    textView.delegate = self;
    textView.autocorrectionType = code ? UITextAutocorrectionTypeNo : UITextAutocorrectionTypeDefault;
    textView.smartQuotesType = UITextSmartQuotesTypeNo;
    textView.smartDashesType = UITextSmartDashesTypeNo;
    if (@available(iOS 18, *))
        textView.writingToolsBehavior = code ? UIWritingToolsBehaviorNone : UIWritingToolsBehaviorComplete;
    if (attributed != nil) {
        textView.allowsEditingTextAttributes = editable;
        textView.attributedText = attributed;
    } else {
        textView.font = code ? [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular] : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        textView.textColor = UIColor.labelColor;
        textView.text = text;
    }
    textView.accessibilityIdentifier = @"clip text";
    self.textView = textView;
    [self pin:textView];
}

- (void)buildImageView:(UIImage *)image {
    self.originalImage = image;
    self.editedImage = image;
    UIScrollView *scroll = [UIScrollView new];
    scroll.delegate = self;
    scroll.minimumZoomScale = 1;
    scroll.maximumZoomScale = 8;
    scroll.backgroundColor = UIColor.secondarySystemBackgroundColor;
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:imageView];
    [NSLayoutConstraint activateConstraints:@[
        [imageView.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [imageView.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [imageView.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [imageView.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [imageView.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [imageView.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleZoom:)];
    doubleTap.numberOfTapsRequired = 2;
    [scroll addGestureRecognizer:doubleTap];
    self.zoomView = scroll;
    self.imageView = imageView;
    [self pin:scroll];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)toggleZoom:(UITapGestureRecognizer *)recognizer {
    if (self.zoomView.zoomScale > 1) {
        [self.zoomView setZoomScale:1 animated:YES];
    } else {
        CGPoint point = [recognizer locationInView:self.imageView];
        [self.zoomView zoomToRect:CGRectMake(point.x - 50, point.y - 50, 100, 100) animated:YES];
    }
}

- (void)buildLinkView:(ClipItem *)item {
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentFill;
    stack.layoutMargins = UIEdgeInsetsMake(24, 24, 24, 24);
    stack.layoutMarginsRelativeArrangement = YES;
    LPLinkMetadata *metadata = [LPLinkMetadata new];
    metadata.URL = metadata.originalURL = item.URL;
    metadata.title = item.linkTitle;
    UIImage *thumbnail = item.thumbnail;
    if (thumbnail != nil)
        metadata.imageProvider = [[NSItemProvider alloc] initWithObject:thumbnail];
    LPLinkView *linkView = [[LPLinkView alloc] initWithMetadata:metadata];
    [stack addArrangedSubview:linkView];
    UITextView *url = [UITextView new];
    url.editable = NO;
    url.scrollEnabled = NO;
    url.backgroundColor = UIColor.clearColor;
    url.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    url.textColor = UIColor.secondaryLabelColor;
    url.text = item.text;
    [stack addArrangedSubview:url];
    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];
    [self pin:scroll];
}

- (void)buildColorView:(ClipItem *)item editable:(BOOL)editable {
    UIColor *color = item.color ?: UIColor.grayColor;
    UIView *container = [UIView new];
    UIView *swatch = [UIView new];
    swatch.backgroundColor = color;
    swatch.layer.cornerRadius = 24;
    swatch.layer.cornerCurve = kCACornerCurveContinuous;
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:swatch];
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    label.text = ColorDescription(color, item.text ?: @"");
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [swatch.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [swatch.topAnchor constraintEqualToAnchor:container.topAnchor constant:32],
        [swatch.widthAnchor constraintEqualToConstant:200],
        [swatch.heightAnchor constraintEqualToConstant:200],
        [label.topAnchor constraintEqualToAnchor:swatch.bottomAnchor constant:24],
        [label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    ]];
    if (editable) {
        if (@available(iOS 14, *)) {
            UIColorWell *well = [UIColorWell new];
            well.supportsAlpha = YES;
            well.title = @"Color";
            well.selectedColor = color;
            [well addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
            well.translatesAutoresizingMaskIntoConstraints = NO;
            [container addSubview:well];
            [NSLayoutConstraint activateConstraints:@[
                [well.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:24],
                [well.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
                [well.widthAnchor constraintEqualToConstant:44],
                [well.heightAnchor constraintEqualToConstant:44],
            ]];
            self.colorWell = well;
        }
    }
    self.swatch = swatch;
    self.colorLabel = label;
    [self pin:container];
}

- (void)colorChanged:(UIColorWell *)well API_AVAILABLE(ios(14.0)) {
    self.dirty = YES;
    self.swatch.backgroundColor = well.selectedColor;
    self.colorLabel.text = ColorDescription(well.selectedColor, @"");
}

#pragma mark Bars

- (UIBarButtonItem *)barItem:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:symbol] style:UIBarButtonItemStylePlain target:self action:action];
    item.accessibilityLabel = label;
    return item;
}

- (UIBarButtonItem *)flexible {
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
}

- (void)setUpPreviewBar {
    ClipItem *item = self.item;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIBarButtonItem *paste = [[UIBarButtonItem alloc] initWithTitle:ClipboardPreferences.shared.pasteToClipboardOnly ? @"Copy" : @"Paste"
                                                              style:UIBarButtonItemStyleDone target:self action:@selector(paste)];
    paste.accessibilityIdentifier = @"preview paste";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *more = [NSMutableArray new];
    [more addObject:[UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) { [weakSelf copyItem:NO]; }]];
    if (item.hasRichText)
        [more addObject:[UIAction actionWithTitle:@"Copy as Plain Text" image:nil identifier:nil handler:^(UIAction *a) { [weakSelf copyItem:YES]; }]];
    if (item.kind != ClipKindFile)
        [more addObject:[UIAction actionWithTitle:@"Edit" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) { [weakSelf startEditing]; }]];
    if (item.kind == ClipKindLink)
        [more addObject:[UIAction actionWithTitle:@"Open Link" image:[UIImage systemImageNamed:@"safari"] identifier:nil handler:^(UIAction *a) {
            [UIApplication openURL:weakSelf.item.URL.absoluteString];
        }]];
    UIAction *delete = [UIAction actionWithTitle:item.pinboardID ? @"Unpin" : @"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
        [weakSelf deleteItem];
    }];
    delete.attributes = UIMenuElementAttributesDestructive;
    [more addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[delete]]];
    UIBarButtonItem *moreItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] menu:[UIMenu menuWithChildren:more]];
    moreItem.accessibilityLabel = @"More";
    UIBarButtonItem *share = [self barItem:@"square.and.arrow.up" label:@"Share" action:@selector(share:)];
    self.navigationItem.rightBarButtonItems = @[paste, moreItem, share];

    if (self.items.count > 1) {
        UIBarButtonItem *previous = [self barItem:@"chevron.left" label:@"Previous Item" action:@selector(previousItem)];
        previous.enabled = self.index > 0;
        UIBarButtonItem *next = [self barItem:@"chevron.right" label:@"Next Item" action:@selector(nextItem)];
        next.enabled = self.index + 1 < self.items.count;
        self.toolbarItems = @[previous, self.flexible, next];
        [self.navigationController setToolbarHidden:NO animated:NO];
    } else {
        [self.navigationController setToolbarHidden:YES animated:NO];
    }
}

- (void)setUpEditingBar {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelEditing)];
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    save.accessibilityIdentifier = @"save item";
    self.navigationItem.rightBarButtonItems = @[save];
    NSMutableArray<UIBarButtonItem *> *tools = [NSMutableArray new];
    ClipItem *item = self.item;
    if (self.textView != nil && (self.mode == PageModeCreate || item.kind == ClipKindText)) {
        if (item.hasRichText) {
            [tools addObjectsFromArray:@[
                [self barItem:@"bold" label:@"Bold" action:@selector(bold)],
                [self barItem:@"italic" label:@"Italic" action:@selector(italic)],
                [self barItem:@"underline" label:@"Underline" action:@selector(underline)],
                [self barItem:@"strikethrough" label:@"Strikethrough" action:@selector(strikethrough)],
            ]];
        }
        if (@available(iOS 18.2, *)) {
            if ([self.textView respondsToSelector:@selector(showWritingTools:)]) {
                [tools addObject:self.flexible];
                [tools addObject:[self barItem:@"apple.writing.tools" label:@"Writing Tools" action:@selector(writingTools:)]];
            }
        }
    } else if (self.imageView != nil) {
        [tools addObjectsFromArray:@[
            [self barItem:@"rotate.left" label:@"Rotate Left" action:@selector(rotateLeft)],
            [self barItem:@"rotate.right" label:@"Rotate Right" action:@selector(rotateRight)],
        ]];
        if (@available(iOS 17, *)) {
            [tools addObject:self.flexible];
            UIBarButtonItem *remove = [[UIBarButtonItem alloc] initWithTitle:@"Remove Background" style:UIBarButtonItemStylePlain target:self action:@selector(toggleBackground:)];
            [tools addObject:remove];
        }
    }
    self.toolbarItems = tools;
    [self.navigationController setToolbarHidden:tools.count == 0 animated:NO];
}

#pragma mark Editing actions

- (void)textViewDidChange:(UITextView *)textView {
    self.dirty = YES;
}

- (void)bold { [self.textView toggleBoldface:nil]; self.dirty = YES; }
- (void)italic { [self.textView toggleItalics:nil]; self.dirty = YES; }
- (void)underline { [self.textView toggleUnderline:nil]; self.dirty = YES; }

- (void)strikethrough {
    UITextView *textView = self.textView;
    NSRange range = textView.selectedRange;
    if (range.length == 0)
        return;
    NSMutableAttributedString *text = [textView.attributedText mutableCopy];
    BOOL on = [[text attribute:NSStrikethroughStyleAttributeName atIndex:range.location effectiveRange:NULL] integerValue] != 0;
    if (on)
        [text removeAttribute:NSStrikethroughStyleAttributeName range:range];
    else
        [text addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    textView.attributedText = text;
    textView.selectedRange = range;
    self.dirty = YES;
}

- (void)writingTools:(id)sender API_AVAILABLE(ios(18.2)) {
    [self.textView showWritingTools:sender];
}

- (void)rotateLeft {
    self.editedImage = RotatedImage(self.editedImage, NO);
    self.imageView.image = self.editedImage;
    self.dirty = YES;
}

- (void)rotateRight {
    self.editedImage = RotatedImage(self.editedImage, YES);
    self.imageView.image = self.editedImage;
    self.dirty = YES;
}

- (void)toggleBackground:(UIBarButtonItem *)sender API_AVAILABLE(ios(17.0)) {
    if (self.editedImage != self.originalImage && [sender.title isEqualToString:@"Restore Background"]) {
        self.editedImage = self.originalImage;
        self.imageView.image = self.editedImage;
        sender.title = @"Remove Background";
        return;
    }
    UIImage *image = self.editedImage;
    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        UIImage *result = ImageWithoutBackground(image, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            if (result == nil) {
                ClipShowToast(self.view, @"No subject found", @"exclamationmark.triangle");
                return;
            }
            self.editedImage = result;
            self.imageView.image = result;
            self.dirty = YES;
            sender.title = @"Restore Background";
        });
    });
}

- (void)save {
    ClipboardStore *store = ClipboardStore.shared;
    if (self.mode == PageModeCreate) {
        NSString *text = self.textView.text ?: @"";
        if ([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0)
            [store addText:text toPinboard:self.pinboard];
        [self.owner dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    ClipItem *item = self.item;
    if (self.dirty) {
        if (self.imageView != nil && self.editedImage != nil) {
            [store updateItem:item image:self.editedImage];
        } else if (self.swatch != nil) {
            [store updateItem:item color:self.swatch.backgroundColor];
        } else if (self.textView != nil) {
            if (item.hasRichText)
                [store updateItem:item attributedText:self.textView.attributedText];
            else
                [store updateItem:item text:self.textView.text ?: @""];
        }
    }
    if (self.owner.startedInEditMode) {
        [self.owner dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.mode = PageModePreview;
    self.dirty = NO;
    [self rebuild];
    [self becomeFirstResponder];
}

- (void)cancelEditing {
    if (self.mode == PageModeCreate || self.owner.startedInEditMode) {
        [self.owner dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.mode = PageModePreview;
    self.dirty = NO;
    [self rebuild];
    [self becomeFirstResponder];
}

- (void)startEditing {
    if (self.item == nil || self.item.kind == ClipKindFile)
        return;
    self.mode = PageModeEdit;
    self.dirty = NO;
    [self rebuild];
    if (self.textView != nil)
        [self.textView becomeFirstResponder];
}

#pragma mark Preview actions

- (void)close {
    [self.owner dismissViewControllerAnimated:YES completion:nil];
}

- (void)paste {
    [self pastePlain:NO];
}

- (void)pastePlain:(BOOL)plainText {
    ClipItem *item = self.item;
    ClipboardItemViewController *owner = self.owner;
    void (^handler)(NSArray<ClipItem *> *, BOOL) = owner.pasteHandler;
    [owner dismissViewControllerAnimated:YES completion:^{
        if (handler != nil && item != nil)
            handler(@[item], plainText);
    }];
}

- (void)copyItem:(BOOL)plainText {
    [ClipboardStore.shared copyItems:@[self.item] plainText:plainText];
    ClipShowToast(self.view, @"Copied", @"doc.on.doc");
}

- (void)deleteItem {
    ClipItem *item = self.item;
    [ClipboardStore.shared deleteItems:@[item]];
    NSMutableArray<ClipItem *> *items = [self.items mutableCopy];
    [items removeObject:item];
    self.items = items;
    if (items.count == 0) {
        [self close];
        return;
    }
    self.index = MIN(self.index, items.count - 1);
    [self rebuild];
}

- (void)share:(UIBarButtonItem *)sender {
    ClipItem *item = self.item;
    id object = item.kind == ClipKindImage ? [item loadImage] : item.kind == ClipKindLink ? item.URL : item.text;
    if (object == nil)
        return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[object] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)previousItem {
    if (self.index == 0)
        return;
    self.index--;
    [self rebuild];
}

- (void)nextItem {
    if (self.index + 1 >= self.items.count)
        return;
    self.index++;
    [self rebuild];
}

#pragma mark Keyboard

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (self.mode != PageModePreview) {
        return @[
            [UIKeyCommand commandWithTitle:@"Save" image:nil action:@selector(save) input:@"s" modifierFlags:UIKeyModifierCommand propertyList:nil],
            [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancelEditing)],
        ];
    }
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray arrayWithArray:@[
        [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(close)],
        [UIKeyCommand keyCommandWithInput:@" " modifierFlags:0 action:@selector(close)],
        [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:0 action:@selector(paste)],
        [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:UIKeyModifierShift action:@selector(pastePlainPressed)],
        [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow modifierFlags:0 action:@selector(previousItem)],
        [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow modifierFlags:0 action:@selector(nextItem)],
        [UIKeyCommand commandWithTitle:@"Edit" image:nil action:@selector(startEditing) input:@"e" modifierFlags:UIKeyModifierCommand propertyList:nil],
    ]];
    for (UIKeyCommand *command in commands)
        command.wantsPriorityOverSystemBehavior = YES;
    return commands;
}

- (void)pastePlainPressed {
    [self pastePlain:YES];
}

- (void)copy:(id)sender {
    if (self.mode == PageModePreview && self.textView.selectedRange.length == 0)
        [self copyItem:NO];
    else
        [self.textView copy:sender];
}

@end

#pragma mark - ClipboardItemViewController

@interface ClipboardItemViewController () <UIAdaptivePresentationControllerDelegate>
@end

@implementation ClipboardItemViewController

- (instancetype)initWithPage:(ClipItemPage *)page {
    if (self = [super initWithRootViewController:page]) {
        page.owner = self;
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        self.presentationController.delegate = self;
    }
    return self;
}

- (instancetype)initWithItems:(NSArray<ClipItem *> *)items index:(NSUInteger)index {
    ClipItemPage *page = [ClipItemPage new];
    page.mode = PageModePreview;
    page.items = items;
    page.index = index;
    return [self initWithPage:page];
}

- (instancetype)initForEditingItem:(ClipItem *)item {
    ClipItemPage *page = [ClipItemPage new];
    page.mode = PageModeEdit;
    page.items = @[item];
    if (self = [self initWithPage:page])
        self.startedInEditMode = YES;
    return self;
}

- (instancetype)initForNewItemInPinboard:(ClipPinboard *)pinboard {
    ClipItemPage *page = [ClipItemPage new];
    page.mode = PageModeCreate;
    page.items = @[];
    page.pinboard = pinboard;
    return [self initWithPage:page];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && self.dismissHandler != nil)
        self.dismissHandler();
}

- (BOOL)presentationControllerShouldDismiss:(UIPresentationController *)presentationController {
    // A swipe must not throw away unsaved edits.
    ClipItemPage *page = (ClipItemPage *) self.viewControllers.firstObject;
    return !page.dirty;
}

@end
