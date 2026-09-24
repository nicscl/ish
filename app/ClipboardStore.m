//
//  ClipboardStore.m
//  iSH
//

#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <LinkPresentation/LinkPresentation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>
#import "ClipboardStore.h"

NSNotificationName const ClipboardStoreDidChangeNotification = @"ClipboardStoreDidChangeNotification";
NSString *const ClipboardUpdatedItemsKey = @"updated";
NSNotificationName const ClipboardStackDidChangeNotification = @"ClipboardStackDidChangeNotification";
NSNotificationName const ClipboardPauseDidChangeNotification = @"ClipboardPauseDidChangeNotification";

// Anything bigger than this is left out of the history.
static const NSUInteger kMaxClipBytes = 64 << 20;
static const CGFloat kThumbnailPixels = 640;

static NSString *const kLastChangeCountKey = @"Clipboard.lastChangeCount";

static atomic_long linuxChangeCount = -1;

void ClipboardNoteLinuxWrite(void) {
    atomic_store(&linuxChangeCount, (long) UIPasteboard.generalPasteboard.changeCount);
}

#pragma mark - Names

NSString *ClipKindName(ClipKind kind) {
    switch (kind) {
        case ClipKindText: return @"Text";
        case ClipKindLink: return @"Link";
        case ClipKindImage: return @"Image";
        case ClipKindFile: return @"File";
        case ClipKindColor: return @"Color";
    }
    return @"Item";
}

NSString *ClipKindSymbol(ClipKind kind) {
    switch (kind) {
        case ClipKindText: return @"text.alignleft";
        case ClipKindLink: return @"link";
        case ClipKindImage: return @"photo";
        case ClipKindFile: return @"doc";
        case ClipKindColor: return @"paintpalette";
    }
    return @"doc.on.clipboard";
}

NSString *ClipSourceName(ClipSource source) {
    switch (source) {
        case ClipSourceOtherApp: return @"Other Apps";
        case ClipSourceTerminal: return @"Terminal";
        case ClipSourceLinux: return @"/dev/clipboard";
        case ClipSourceCreated: return @"Created in iSH";
    }
    return @"";
}

NSString *ClipSourceSymbol(ClipSource source) {
    switch (source) {
        case ClipSourceOtherApp: return @"square.grid.2x2";
        case ClipSourceTerminal: return @"terminal";
        case ClipSourceLinux: return @"chevron.left.forwardslash.chevron.right";
        case ClipSourceCreated: return @"square.and.pencil";
    }
    return @"questionmark";
}

NSString *ClipDateFilterName(ClipDateFilter filter) {
    switch (filter) {
        case ClipDateAny: return @"Any Time";
        case ClipDateToday: return @"Today";
        case ClipDateYesterday: return @"Yesterday";
        case ClipDateLastWeek: return @"Last Week";
        case ClipDateLastMonth: return @"Last Month";
    }
    return @"";
}

NSString *ClipRetentionName(ClipRetention retention) {
    switch (retention) {
        case ClipRetentionDay: return @"Day";
        case ClipRetentionWeek: return @"Week";
        case ClipRetentionMonth: return @"Month";
        case ClipRetentionYear: return @"Year";
        case ClipRetentionForever: return @"Forever";
    }
    return @"";
}

static NSTimeInterval RetentionInterval(ClipRetention retention) {
    switch (retention) {
        case ClipRetentionDay: return 24 * 3600;
        case ClipRetentionWeek: return 7 * 24 * 3600;
        case ClipRetentionMonth: return 31 * 24 * 3600;
        case ClipRetentionYear: return 366 * 24 * 3600;
        case ClipRetentionForever: return 0;
    }
    return 0;
}

NSArray<UIColor *> *ClipPinboardColors(void) {
    return @[UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemYellowColor, UIColor.systemGreenColor,
             UIColor.systemTealColor, UIColor.systemBlueColor, UIColor.systemIndigoColor, UIColor.systemPurpleColor,
             UIColor.systemPinkColor, UIColor.systemBrownColor, UIColor.systemGrayColor];
}

NSArray<NSString *> *ClipPinboardColorNames(void) {
    return @[@"Red", @"Orange", @"Yellow", @"Green", @"Teal", @"Blue", @"Indigo", @"Purple", @"Pink", @"Brown", @"Gray"];
}

#pragma mark - Pasteboard contents

static BOOL TypeConforms(NSString *type, UTType *to) {
    UTType *t = [UTType typeWithIdentifier:type];
    return t != nil && [t conformsToType:to];
}

static NSString *TextFromData(NSData *data, NSString *type) {
    if ([type isEqualToString:@"public.utf16-plain-text"])
        return [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if ([type isEqualToString:@"public.utf16-external-plain-text"])
        return [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Converts what UIPasteboard.items hands out (strings, URLs, images, plists) to data.
static NSData *DataForPasteboardValue(id value, NSString *type) {
    if ([value isKindOfClass:NSData.class])
        return value;
    if ([value isKindOfClass:NSString.class])
        return [value dataUsingEncoding:NSUTF8StringEncoding];
    if ([value isKindOfClass:NSURL.class])
        return [[value absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
    if ([value isKindOfClass:NSAttributedString.class]) {
        NSAttributedString *string = value;
        return [string dataFromRange:NSMakeRange(0, string.length)
                  documentAttributes:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType} error:nil];
    }
    if ([value isKindOfClass:UIImage.class]) {
        if (TypeConforms(type, UTTypeJPEG))
            return UIImageJPEGRepresentation(value, 0.95);
        return UIImagePNGRepresentation(value);
    }
    if ([NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return nil;
}

// The reverse, for putting items back: UIPasteboard wants strings and URLs for the
// standard text and URL types.
static id PasteboardValueForData(NSData *data, NSString *type) {
    if (TypeConforms(type, UTTypePlainText))
        return TextFromData(data, type) ?: data;
    if ([type isEqualToString:UTTypeURL.identifier] || [type isEqualToString:UTTypeFileURL.identifier]) {
        NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSURL *url = string ? [NSURL URLWithString:string] : nil;
        return url ?: data;
    }
    return data;
}

static NSString *PlainTextInItem(NSDictionary<NSString *, NSData *> *item) {
    for (NSString *type in @[@"public.utf8-plain-text", @"public.plain-text", @"public.utf16-plain-text", @"public.text"]) {
        NSData *data = item[type];
        if (data != nil) {
            NSString *text = TextFromData(data, type);
            if (text != nil)
                return text;
        }
    }
    for (NSString *type in item) {
        if (TypeConforms(type, UTTypePlainText)) {
            NSString *text = TextFromData(item[type], type);
            if (text != nil)
                return text;
        }
    }
    return nil;
}

static NSArray<NSString *> *RichTextTypes(void) {
    return @[UTTypeRTFD.identifier, UTTypeFlatRTFD.identifier, UTTypeRTF.identifier, UTTypeHTML.identifier];
}

static NSAttributedString *AttributedTextInItem(NSDictionary<NSString *, NSData *> *item) {
    NSDictionary *documentTypes = @{
        UTTypeRTFD.identifier: NSRTFDTextDocumentType,
        UTTypeFlatRTFD.identifier: NSRTFDTextDocumentType,
        UTTypeRTF.identifier: NSRTFTextDocumentType,
        UTTypeHTML.identifier: NSHTMLTextDocumentType,
    };
    for (NSString *type in RichTextTypes()) {
        NSData *data = item[type];
        if (data == nil)
            continue;
        NSMutableDictionary *options = [@{NSDocumentTypeDocumentOption: documentTypes[type]} mutableCopy];
        if ([type isEqualToString:UTTypeHTML.identifier])
            options[NSCharacterEncodingDocumentOption] = @(NSUTF8StringEncoding);
        NSAttributedString *text = [[NSAttributedString alloc] initWithData:data options:options documentAttributes:nil error:nil];
        if (text != nil)
            return text;
    }
    return nil;
}

static NSData *ImageDataInItem(NSDictionary<NSString *, NSData *> *item) {
    for (NSString *type in item) {
        if (TypeConforms(type, UTTypeImage))
            return item[type];
    }
    return nil;
}

static NSArray<NSURL *> *URLsInItems(NSArray<NSDictionary<NSString *, NSData *> *> *items, NSString *type) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray new];
    for (NSDictionary<NSString *, NSData *> *item in items) {
        NSData *data = item[type];
        NSString *string = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *url = string ? [NSURL URLWithString:string] : nil;
        if (url != nil)
            [urls addObject:url];
    }
    return urls;
}

static NSString *ChecksumOfItems(NSArray<NSDictionary<NSString *, NSData *> *> *items) {
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (NSDictionary<NSString *, NSData *> *item in items) {
        for (NSString *type in [item.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSData *typeData = [type dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256_Update(&ctx, typeData.bytes, (CC_LONG) typeData.length);
            NSData *data = item[type];
            CC_SHA256_Update(&ctx, data.bytes, (CC_LONG) data.length);
        }
        CC_SHA256_Update(&ctx, "\n", 1);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < 16; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark Text classification

static UIColor *ColorFromString(NSString *string) {
    NSString *s = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length > 40)
        return nil;
    static NSRegularExpression *hexPattern, *rgbPattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hexPattern = [NSRegularExpression regularExpressionWithPattern:@"^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$"
                                                              options:NSRegularExpressionCaseInsensitive error:nil];
        rgbPattern = [NSRegularExpression regularExpressionWithPattern:@"^rgba?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*(?:,\\s*([0-9.]+)\\s*)?\\)$"
                                                              options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSRange all = NSMakeRange(0, s.length);
    if ([hexPattern firstMatchInString:s options:0 range:all] != nil) {
        NSString *hex = [s substringFromIndex:1];
        if (hex.length == 3)
            hex = [NSString stringWithFormat:@"%C%C%C%C%C%C", [hex characterAtIndex:0], [hex characterAtIndex:0],
                   [hex characterAtIndex:1], [hex characterAtIndex:1], [hex characterAtIndex:2], [hex characterAtIndex:2]];
        unsigned long long value = 0;
        [[NSScanner scannerWithString:hex] scanHexLongLong:&value];
        CGFloat alpha = 1;
        if (hex.length == 8) {
            alpha = (value & 0xff) / 255.0;
            value >>= 8;
        }
        return [UIColor colorWithRed:((value >> 16) & 0xff) / 255.0 green:((value >> 8) & 0xff) / 255.0
                                blue:(value & 0xff) / 255.0 alpha:alpha];
    }
    NSTextCheckingResult *rgb = [rgbPattern firstMatchInString:s options:0 range:all];
    if (rgb != nil) {
        CGFloat c[3];
        for (int i = 0; i < 3; i++)
            c[i] = MIN([[s substringWithRange:[rgb rangeAtIndex:i + 1]] intValue], 255) / 255.0;
        CGFloat alpha = [rgb rangeAtIndex:4].location != NSNotFound ? [[s substringWithRange:[rgb rangeAtIndex:4]] doubleValue] : 1;
        return [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:MIN(MAX(alpha, 0), 1)];
    }
    return nil;
}

static NSString *HexStringForColor(UIColor *color) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a])
        return @"#000000";
    int ri = (int) lround(MIN(MAX(r, 0), 1) * 255), gi = (int) lround(MIN(MAX(g, 0), 1) * 255), bi = (int) lround(MIN(MAX(b, 0), 1) * 255);
    if (a < 0.999)
        return [NSString stringWithFormat:@"#%02X%02X%02X%02X", ri, gi, bi, (int) lround(a * 255)];
    return [NSString stringWithFormat:@"#%02X%02X%02X", ri, gi, bi];
}

static NSURL *LinkFromString(NSString *string) {
    NSString *s = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length == 0 || s.length > 4096 || [s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return nil;
    NSURL *url = [NSURL URLWithString:s];
    NSString *scheme = url.scheme.lowercaseString;
    if (url != nil && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && url.host.length > 0)
        return url;
    if (url != nil && ([scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"ftp"] || [scheme isEqualToString:@"ssh"]))
        return url;
    return nil;
}

// A rough guess, for showing a card in a monospaced dark style.
static BOOL TextLooksLikeCode(NSString *text) {
    if (text.length == 0 || text.length > 200000)
        return NO;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger nonEmpty = 0, codeish = 0;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0)
            continue;
        nonEmpty++;
        BOOL indented = [raw hasPrefix:@"    "] || [raw hasPrefix:@"\t"];
        if (indented || [line hasSuffix:@";"] || [line hasSuffix:@"{"] || [line hasSuffix:@"}"] || [line hasSuffix:@")"] ||
            [line hasPrefix:@"#"] || [line hasPrefix:@"//"] || [line hasPrefix:@"$ "] || [line hasPrefix:@"import "] ||
            [line containsString:@" = "] || [line containsString:@"=>"] || [line containsString:@"->"] ||
            [line containsString:@"()"] || [line containsString:@"&&"] || [line containsString:@" | "])
            codeish++;
    }
    if (nonEmpty == 0)
        return NO;
    if (nonEmpty == 1)
        return codeish == 1 && text.length < 200 && ([text containsString:@"("] || [text containsString:@"$"] ||
                                                     [text containsString:@"&&"] || [text containsString:@"|"] ||
                                                     [text hasSuffix:@";"]);
    return codeish * 10 >= nonEmpty * 4;
}

#pragma mark Images

static UIImage *DownscaledImage(UIImage *image, CGFloat maxPixels) {
    CGSize size = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    CGFloat factor = MIN(1, maxPixels / MAX(size.width, size.height));
    CGSize target = CGSizeMake(MAX(1, floor(size.width * factor)), MAX(1, floor(size.height * factor)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:target format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

static BOOL ImageHasAlpha(UIImage *image) {
    CGImageAlphaInfo info = CGImageGetAlphaInfo(image.CGImage);
    return info != kCGImageAlphaNone && info != kCGImageAlphaNoneSkipFirst && info != kCGImageAlphaNoneSkipLast;
}

static NSData *ThumbnailData(UIImage *image) {
    UIImage *thumb = DownscaledImage(image, kThumbnailPixels);
    return ImageHasAlpha(image) ? UIImagePNGRepresentation(thumb) : UIImageJPEGRepresentation(thumb, 0.8);
}

#pragma mark - ClipItem

@interface ClipItem ()
@property NSString *identifier;
@property ClipKind kind;
@property NSDate *createdAt;
@property NSDate *copiedAt;
@property (nullable) NSString *title;
@property (nullable) NSString *text;
@property BOOL hasRichText;
@property ClipSource source;
@property (nullable) NSString *sourceDetail;
@property (nullable) NSString *pinboardID;
@property double order;
@property CGSize imageSize;
@property (nullable) NSString *linkTitle;
@property BOOL linkFetched;
@property NSString *checksum;
@property NSString *dataFile;
@property (nullable) NSString *thumbFile;
@property BOOL looksLikeCode;
@end

@interface ClipboardStore ()
@property NSURL *directory;
- (void)pruneHistory;
@property NSCache<NSString *, UIImage *> *thumbnails;
- (NSURL *)dataURL:(NSString *)file;
- (NSURL *)thumbURL:(NSString *)file;
@end

@implementation ClipItem

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary new];
    d[@"id"] = self.identifier;
    d[@"kind"] = @(self.kind);
    d[@"created"] = @(self.createdAt.timeIntervalSince1970);
    d[@"copied"] = @(self.copiedAt.timeIntervalSince1970);
    d[@"title"] = self.title;
    d[@"text"] = self.text;
    d[@"rich"] = @(self.hasRichText);
    d[@"source"] = @(self.source);
    d[@"detail"] = self.sourceDetail;
    d[@"pinboard"] = self.pinboardID;
    d[@"order"] = @(self.order);
    if (self.kind == ClipKindImage) {
        d[@"w"] = @(self.imageSize.width);
        d[@"h"] = @(self.imageSize.height);
    }
    d[@"linkTitle"] = self.linkTitle;
    d[@"linkFetched"] = @(self.linkFetched);
    d[@"checksum"] = self.checksum;
    d[@"data"] = self.dataFile;
    d[@"thumb"] = self.thumbFile;
    return d;
}

static id Field(NSDictionary *d, NSString *key, Class cls) {
    id value = d[key];
    return [value isKindOfClass:cls] ? value : nil;
}

- (void)applyDictionary:(NSDictionary *)d {
    self.identifier = Field(d, @"id", NSString.class) ?: NSUUID.UUID.UUIDString;
    self.kind = [Field(d, @"kind", NSNumber.class) integerValue];
    self.createdAt = [NSDate dateWithTimeIntervalSince1970:[Field(d, @"created", NSNumber.class) doubleValue]];
    self.copiedAt = [NSDate dateWithTimeIntervalSince1970:[Field(d, @"copied", NSNumber.class) doubleValue]];
    self.title = Field(d, @"title", NSString.class);
    self.text = Field(d, @"text", NSString.class);
    self.hasRichText = [Field(d, @"rich", NSNumber.class) boolValue];
    self.source = [Field(d, @"source", NSNumber.class) integerValue];
    self.sourceDetail = Field(d, @"detail", NSString.class);
    self.pinboardID = Field(d, @"pinboard", NSString.class);
    self.order = [Field(d, @"order", NSNumber.class) doubleValue];
    self.imageSize = CGSizeMake([Field(d, @"w", NSNumber.class) doubleValue], [Field(d, @"h", NSNumber.class) doubleValue]);
    self.linkTitle = Field(d, @"linkTitle", NSString.class);
    self.linkFetched = [Field(d, @"linkFetched", NSNumber.class) boolValue];
    self.checksum = Field(d, @"checksum", NSString.class) ?: @"";
    self.dataFile = Field(d, @"data", NSString.class) ?: @"";
    self.thumbFile = Field(d, @"thumb", NSString.class);
    self.looksLikeCode = self.kind == ClipKindText && !self.hasRichText &&
        TextLooksLikeCode(self.text);
}

+ (instancetype)itemWithDictionary:(NSDictionary *)d {
    ClipItem *item = [ClipItem new];
    [item applyDictionary:d];
    return item;
}

- (ClipItem *)cloneWithNewIdentifier {
    NSMutableDictionary *d = [self.dictionaryRepresentation mutableCopy];
    d[@"id"] = NSUUID.UUID.UUIDString;
    return [ClipItem itemWithDictionary:d];
}

- (UIColor *)color {
    return self.kind == ClipKindColor ? ColorFromString(self.text) : nil;
}

- (NSURL *)URL {
    if (self.kind == ClipKindLink)
        return LinkFromString(self.text) ?: [NSURL URLWithString:self.text];
    if (self.kind == ClipKindFile) {
        NSString *first = [self.text componentsSeparatedByString:@"\n"].firstObject;
        return first.length > 0 ? [NSURL fileURLWithPath:first] : nil;
    }
    return nil;
}

- (NSString *)displayTitle {
    if (self.title.length > 0)
        return self.title;
    if (self.linkTitle.length > 0)
        return self.linkTitle;
    if (self.kind == ClipKindFile) {
        NSArray<NSString *> *paths = [self.text componentsSeparatedByString:@"\n"];
        return paths.count > 1 ? [NSString stringWithFormat:@"%lu files", (unsigned long) paths.count]
                               : (paths.firstObject.lastPathComponent ?: ClipKindName(self.kind));
    }
    for (NSString *line in [self.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length > 0)
            return trimmed.length > 80 ? [[trimmed substringToIndex:80] stringByAppendingString:@"…"] : trimmed;
    }
    return ClipKindName(self.kind);
}

- (NSString *)footnote {
    switch (self.kind) {
        case ClipKindText: {
            static NSNumberFormatter *formatter;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                formatter = [NSNumberFormatter new];
                formatter.numberStyle = NSNumberFormatterDecimalStyle;
            });
            NSUInteger count = self.text.length;
            return [NSString stringWithFormat:@"%@ character%@", [formatter stringFromNumber:@(count)], count == 1 ? @"" : @"s"];
        }
        case ClipKindImage:
            if (self.imageSize.width > 0)
                return [NSString stringWithFormat:@"%.0f × %.0f", self.imageSize.width, self.imageSize.height];
            return nil;
        case ClipKindLink: {
            NSString *host = self.URL.host;
            if ([host hasPrefix:@"www."])
                host = [host substringFromIndex:4];
            return host ?: self.URL.scheme;
        }
        case ClipKindFile:
        case ClipKindColor:
            return nil;
    }
    return nil;
}

- (UIImage *)thumbnail {
    if (self.thumbFile == nil)
        return nil;
    ClipboardStore *store = ClipboardStore.shared;
    UIImage *image = [store.thumbnails objectForKey:self.thumbFile];
    if (image == nil) {
        image = [UIImage imageWithContentsOfFile:[store thumbURL:self.thumbFile].path];
        if (image != nil)
            [store.thumbnails setObject:image forKey:self.thumbFile];
    }
    return image;
}

- (NSArray<NSDictionary<NSString *, NSData *> *> *)loadPasteboardItems {
    NSData *data = [NSData dataWithContentsOfURL:[ClipboardStore.shared dataURL:self.dataFile]];
    id items = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![items isKindOfClass:NSArray.class])
        return self.text ? @[@{UTTypeUTF8PlainText.identifier: [self.text dataUsingEncoding:NSUTF8StringEncoding]}] : @[];
    return items;
}

- (UIImage *)loadImage {
    for (NSDictionary<NSString *, NSData *> *item in self.loadPasteboardItems) {
        NSData *data = ImageDataInItem(item);
        if (data != nil)
            return [UIImage imageWithData:data];
    }
    return nil;
}

- (NSAttributedString *)loadAttributedText {
    if (!self.hasRichText)
        return nil;
    NSDictionary *item = self.loadPasteboardItems.firstObject;
    return item ? AttributedTextInItem(item) : nil;
}

- (BOOL)matchesText:(NSString *)query {
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    for (NSString *field in @[self.title ?: @"", self.text ?: @"", self.linkTitle ?: @"", self.sourceDetail ?: @""]) {
        if ([field rangeOfString:query options:options].location != NSNotFound)
            return YES;
    }
    return NO;
}

@end

#pragma mark - ClipPinboard

@interface ClipPinboard ()
@property NSString *identifier;
@property NSString *name;
@property NSInteger colorIndex;
@end

@implementation ClipPinboard

- (UIColor *)color {
    NSArray<UIColor *> *colors = ClipPinboardColors();
    return colors[(NSUInteger) MAX(0, self.colorIndex) % colors.count];
}

- (NSDictionary *)dictionaryRepresentation {
    return @{@"id": self.identifier, @"name": self.name, @"color": @(self.colorIndex)};
}

+ (instancetype)pinboardWithDictionary:(NSDictionary *)d {
    ClipPinboard *pinboard = [ClipPinboard new];
    pinboard.identifier = Field(d, @"id", NSString.class) ?: NSUUID.UUID.UUIDString;
    pinboard.name = Field(d, @"name", NSString.class) ?: @"Pinboard";
    pinboard.colorIndex = [Field(d, @"color", NSNumber.class) integerValue];
    return pinboard;
}

@end

#pragma mark - ClipQuery

@implementation ClipQuery

- (instancetype)init {
    if (self = [super init])
        _text = @"";
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    ClipQuery *copy = [ClipQuery new];
    copy.text = self.text;
    copy.kinds = self.kinds;
    copy.sources = self.sources;
    copy.pinboardIDs = self.pinboardIDs;
    copy.date = self.date;
    return copy;
}

- (BOOL)isEmpty {
    return [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0 &&
        self.kinds.count == 0 && self.sources.count == 0 && self.pinboardIDs.count == 0 && self.date == ClipDateAny;
}

- (BOOL)matchesItem:(ClipItem *)item {
    if (self.kinds.count > 0 && ![self.kinds containsObject:@(item.kind)])
        return NO;
    if (self.sources.count > 0 && ![self.sources containsObject:@(item.source)])
        return NO;
    if (self.pinboardIDs.count > 0 && ![self.pinboardIDs containsObject:item.pinboardID ?: @""])
        return NO;
    if (self.date != ClipDateAny) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDate *startOfToday = [calendar startOfDayForDate:NSDate.date];
        NSDate *date = item.copiedAt;
        switch (self.date) {
            case ClipDateToday:
                if ([date compare:startOfToday] == NSOrderedAscending) return NO;
                break;
            case ClipDateYesterday: {
                NSDate *startOfYesterday = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:startOfToday options:0];
                if ([date compare:startOfYesterday] == NSOrderedAscending || [date compare:startOfToday] != NSOrderedAscending)
                    return NO;
                break;
            }
            case ClipDateLastWeek:
                if ([date compare:[calendar dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:startOfToday options:0]] == NSOrderedAscending)
                    return NO;
                break;
            case ClipDateLastMonth:
                if ([date compare:[calendar dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:startOfToday options:0]] == NSOrderedAscending)
                    return NO;
                break;
            case ClipDateAny:
                break;
        }
    }
    NSArray<NSString *> *words = [self.text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (NSString *word in words) {
        if (word.length > 0 && ![item matchesText:word])
            return NO;
    }
    return YES;
}

@end

#pragma mark - ClipboardPreferences

@implementation ClipboardPreferences

static NSString *PrefKey(NSString *name) {
    return [@"Clipboard." stringByAppendingString:name];
}

+ (instancetype)shared {
    static ClipboardPreferences *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            PrefKey(@"collectFromOtherApps"): @YES,
            PrefKey(@"pasteToClipboardOnly"): @NO,
            PrefKey(@"alwaysPlainText"): @NO,
            PrefKey(@"retention"): @(ClipRetentionMonth),
            PrefKey(@"cardSize"): @(ClipCardSizeRegular),
            PrefKey(@"ignoreConfidential"): @YES,
            PrefKey(@"ignoreTransient"): @YES,
            PrefKey(@"linkPreviews"): @YES,
            PrefKey(@"soundEffects"): @NO,
        }];
        shared = [ClipboardPreferences new];
    });
    return shared;
}

#define BOOL_PREF(getter, setter) \
    - (BOOL)getter { return [NSUserDefaults.standardUserDefaults boolForKey:PrefKey(@#getter)]; } \
    - (void)setter:(BOOL)value { [NSUserDefaults.standardUserDefaults setBool:value forKey:PrefKey(@#getter)]; }

BOOL_PREF(collectFromOtherApps, setCollectFromOtherApps)
BOOL_PREF(pasteToClipboardOnly, setPasteToClipboardOnly)
BOOL_PREF(alwaysPlainText, setAlwaysPlainText)
BOOL_PREF(ignoreConfidential, setIgnoreConfidential)
BOOL_PREF(ignoreTransient, setIgnoreTransient)
BOOL_PREF(linkPreviews, setLinkPreviews)
BOOL_PREF(soundEffects, setSoundEffects)

- (ClipRetention)retention {
    return [NSUserDefaults.standardUserDefaults integerForKey:PrefKey(@"retention")];
}
- (void)setRetention:(ClipRetention)retention {
    [NSUserDefaults.standardUserDefaults setInteger:retention forKey:PrefKey(@"retention")];
    [ClipboardStore.shared pruneHistory];
}

- (ClipCardSize)cardSize {
    return [NSUserDefaults.standardUserDefaults integerForKey:PrefKey(@"cardSize")];
}
- (void)setCardSize:(ClipCardSize)cardSize {
    [NSUserDefaults.standardUserDefaults setInteger:cardSize forKey:PrefKey(@"cardSize")];
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStoreDidChangeNotification object:ClipboardStore.shared];
}

@end

#pragma mark - ClipboardStore

// A capture on its way from the pasteboard (or a drop) into the store.
@interface ClipCapture : NSObject
@property NSArray<NSDictionary<NSString *, NSData *> *> *items;
@property ClipSource source;
@property (nullable) NSString *sourceDetail;
@property (nullable) NSString *pinboardID;
@property NSUInteger index;
@property BOOL forStack;
@end
@implementation ClipCapture
@end

@interface ClipboardStore ()
@property NSMutableArray<ClipItem *> *items;
@property NSMutableArray<ClipPinboard *> *pinboardList;
@property dispatch_queue_t ioQueue;
@property BOOL started;
@property BOOL saveScheduled;
@property NSInteger lastChangeCount;
@property NSInteger ownChangeCount;
@property NSTimer *pollTimer;
@property NSTimer *resumeTimer;
@property (readwrite) BOOL paused;
@property (readwrite, nullable) NSDate *pausedUntil;
@property NSMutableArray<ClipItem *> *stack;
@property (readwrite) NSUndoManager *undoManager;
@property NSMutableSet<NSString *> *fetchingLinks;
@end

@implementation ClipboardStore

+ (instancetype)shared {
    static ClipboardStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [ClipboardStore new];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _items = [NSMutableArray new];
        _pinboardList = [NSMutableArray new];
        _stack = [NSMutableArray new];
        _ioQueue = dispatch_queue_create("app.ish.clipboard", DISPATCH_QUEUE_SERIAL);
        _thumbnails = [NSCache new];
        _thumbnails.countLimit = 300;
        _undoManager = [NSUndoManager new];
        _fetchingLinks = [NSMutableSet new];
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _directory = [support URLByAppendingPathComponent:@"Clipboard" isDirectory:YES];
        for (NSString *sub in @[@"Data", @"Thumbnails"]) {
            [NSFileManager.defaultManager createDirectoryAtURL:[_directory URLByAppendingPathComponent:sub]
                                   withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return self;
}

- (NSURL *)indexURL {
    return [self.directory URLByAppendingPathComponent:@"index.json"];
}
- (NSURL *)dataURL:(NSString *)file {
    return [[self.directory URLByAppendingPathComponent:@"Data"] URLByAppendingPathComponent:file];
}
- (NSURL *)thumbURL:(NSString *)file {
    return [[self.directory URLByAppendingPathComponent:@"Thumbnails"] URLByAppendingPathComponent:file];
}

#pragma mark Loading and saving

- (void)start {
    if (self.started)
        return;
    self.started = YES;
    [self load];
    [self pruneHistory];
    self.lastChangeCount = [NSUserDefaults.standardUserDefaults integerForKey:kLastChangeCountKey];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(pasteboardChanged:) name:UIPasteboardChangedNotification object:nil];
    [center addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self appDidBecomeActive:nil];
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfURL:self.indexURL];
    NSDictionary *index = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![index isKindOfClass:NSDictionary.class])
        index = @{};
    for (NSDictionary *d in Field(index, @"pinboards", NSArray.class)) {
        if ([d isKindOfClass:NSDictionary.class])
            [self.pinboardList addObject:[ClipPinboard pinboardWithDictionary:d]];
    }
    NSMutableSet<NSString *> *pinboardIDs = [NSMutableSet new];
    for (ClipPinboard *pinboard in self.pinboardList)
        [pinboardIDs addObject:pinboard.identifier];
    for (NSDictionary *d in Field(index, @"items", NSArray.class)) {
        if (![d isKindOfClass:NSDictionary.class])
            continue;
        ClipItem *item = [ClipItem itemWithDictionary:d];
        if (item.pinboardID != nil && ![pinboardIDs containsObject:item.pinboardID])
            continue;
        [self.items addObject:item];
    }
    [self collectGarbage];
}

// Data files are shared by pinned copies and kept around for undo, so they are
// only deleted here, at launch, once nothing refers to them.
- (void)collectGarbage {
    NSMutableSet<NSString *> *live = [NSMutableSet new];
    for (ClipItem *item in self.items) {
        [live addObject:item.dataFile];
        if (item.thumbFile)
            [live addObject:item.thumbFile];
    }
    dispatch_async(self.ioQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *sub in @[@"Data", @"Thumbnails"]) {
            NSURL *dir = [self.directory URLByAppendingPathComponent:sub];
            for (NSString *name in [fm contentsOfDirectoryAtPath:dir.path error:nil]) {
                if (![live containsObject:name])
                    [fm removeItemAtURL:[dir URLByAppendingPathComponent:name] error:nil];
            }
        }
    });
}

- (void)changed:(nullable NSSet<NSString *> *)updated {
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStoreDidChangeNotification
                                                      object:self
                                                    userInfo:updated.count ? @{ClipboardUpdatedItemsKey: updated} : nil];
    [self scheduleSave];
}

- (void)scheduleSave {
    if (self.saveScheduled)
        return;
    self.saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.saveScheduled = NO;
        [self saveNow];
    });
}

- (void)saveNow {
    NSMutableArray *pinboards = [NSMutableArray new];
    for (ClipPinboard *pinboard in self.pinboardList)
        [pinboards addObject:pinboard.dictionaryRepresentation];
    NSMutableArray *items = [NSMutableArray new];
    for (ClipItem *item in self.items)
        [items addObject:item.dictionaryRepresentation];
    NSDictionary *index = @{@"version": @1, @"pinboards": pinboards, @"items": items};
    NSURL *url = self.indexURL;
    dispatch_async(self.ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:index options:0 error:nil];
        [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    });
}

#pragma mark Lists

- (NSArray<ClipPinboard *> *)pinboards {
    return [self.pinboardList copy];
}

- (ClipPinboard *)pinboardWithID:(NSString *)identifier {
    for (ClipPinboard *pinboard in self.pinboardList) {
        if ([pinboard.identifier isEqualToString:identifier])
            return pinboard;
    }
    return nil;
}

static NSComparisonResult NewestFirst(ClipItem *a, ClipItem *b) {
    return [b.copiedAt compare:a.copiedAt];
}

- (NSArray<ClipItem *> *)itemsInPinboard:(ClipPinboard *)pinboard {
    NSString *identifier = pinboard.identifier;
    NSMutableArray<ClipItem *> *result = [NSMutableArray new];
    for (ClipItem *item in self.items) {
        if (identifier == nil ? item.pinboardID == nil : [item.pinboardID isEqualToString:identifier])
            [result addObject:item];
    }
    if (identifier == nil) {
        [result sortUsingComparator:^NSComparisonResult(ClipItem *a, ClipItem *b) { return NewestFirst(a, b); }];
    } else {
        [result sortUsingComparator:^NSComparisonResult(ClipItem *a, ClipItem *b) {
            return a.order < b.order ? NSOrderedAscending : a.order > b.order ? NSOrderedDescending : NSOrderedSame;
        }];
    }
    return result;
}

- (NSArray<ClipItem *> *)itemsMatchingQuery:(ClipQuery *)query {
    NSMutableArray<ClipItem *> *result = [NSMutableArray new];
    for (ClipItem *item in self.items) {
        if ([query matchesItem:item])
            [result addObject:item];
    }
    [result sortUsingComparator:^NSComparisonResult(ClipItem *a, ClipItem *b) { return NewestFirst(a, b); }];
    return result;
}

- (ClipItem *)itemWithID:(NSString *)identifier {
    for (ClipItem *item in self.items) {
        if ([item.identifier isEqualToString:identifier])
            return item;
    }
    for (ClipItem *item in self.stack) {
        if ([item.identifier isEqualToString:identifier])
            return item;
    }
    return nil;
}

- (NSUInteger)historyCount {
    NSUInteger count = 0;
    for (ClipItem *item in self.items)
        count += item.pinboardID == nil;
    return count;
}

- (ClipItem *)historyItemWithChecksum:(NSString *)checksum {
    for (ClipItem *item in self.items) {
        if (item.pinboardID == nil && [item.checksum isEqualToString:checksum])
            return item;
    }
    return nil;
}

- (void)pruneHistory {
    NSTimeInterval interval = RetentionInterval(ClipboardPreferences.shared.retention);
    if (interval == 0)
        return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-interval];
    NSIndexSet *old = [self.items indexesOfObjectsPassingTest:^BOOL(ClipItem *item, NSUInteger i, BOOL *stop) {
        return item.pinboardID == nil && [item.copiedAt compare:cutoff] == NSOrderedAscending;
    }];
    if (old.count == 0)
        return;
    [self.items removeObjectsAtIndexes:old];
    [self changed:nil];
}

#pragma mark Capture

- (void)appDidBecomeActive:(NSNotification *)notif {
    [self checkPasteboard];
    // Another app in Split View or Slide Over can copy while iSH stays active.
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        if (UIPasteboard.generalPasteboard.changeCount != self.lastChangeCount) {
            // Give the change notification for iSH's own copies the first go, so they
            // are attributed to the terminal rather than to another app.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self checkPasteboard];
            });
        }
    }];
}

- (void)appWillResignActive:(NSNotification *)notif {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)pasteboardChanged:(NSNotification *)notif {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
        NSInteger count = pasteboard.changeCount;
        ClipSource source = count == atomic_load(&linuxChangeCount) ? ClipSourceLinux : ClipSourceTerminal;
        [self capturePasteboardAsSource:source];
    });
}

- (void)checkPasteboard {
    if (!self.started)
        return;
    NSInteger count = UIPasteboard.generalPasteboard.changeCount;
    if (count == self.lastChangeCount)
        return;
    if (count == atomic_load(&linuxChangeCount)) {
        [self capturePasteboardAsSource:ClipSourceLinux];
    } else if (ClipboardPreferences.shared.collectFromOtherApps) {
        [self capturePasteboardAsSource:ClipSourceOtherApp];
    } else {
        [self setSeenChangeCount:count];
    }
}

- (void)setSeenChangeCount:(NSInteger)count {
    self.lastChangeCount = count;
    [NSUserDefaults.standardUserDefaults setInteger:count forKey:kLastChangeCountKey];
}

- (void)capturePasteboardAsSource:(ClipSource)source {
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSInteger count = pasteboard.changeCount;
    if (count == self.lastChangeCount)
        return;
    [self setSeenChangeCount:count];
    if (count == self.ownChangeCount)
        return; // put there by copyItems:, which has already recorded it
    if (self.pausedUntil != nil && [self.pausedUntil compare:NSDate.date] != NSOrderedDescending)
        [self resume];
    if (self.paused)
        return;

    // Types can be checked without reading the contents, which for another app's
    // copy is what asks the user for permission.
    NSMutableSet<NSString *> *types = [NSMutableSet new];
    for (NSArray<NSString *> *itemTypes in [pasteboard pasteboardTypesForItemSet:nil] ?: @[])
        [types addObjectsFromArray:itemTypes];
    if (types.count == 0)
        return;
    ClipboardPreferences *prefs = ClipboardPreferences.shared;
    if (prefs.ignoreConfidential && [types containsObject:@"org.nspasteboard.ConcealedType"])
        return;
    if (prefs.ignoreTransient && ([types containsObject:@"org.nspasteboard.TransientType"] ||
                                  [types containsObject:@"org.nspasteboard.AutoGeneratedType"]))
        return;

    NSArray<NSDictionary<NSString *, id> *> *raw = pasteboard.items;
    if (raw.count == 0)
        return;
    ClipCapture *capture = [ClipCapture new];
    capture.source = source;
    if (source == ClipSourceTerminal || source == ClipSourceLinux)
        capture.sourceDetail = self.currentTabTitle ? self.currentTabTitle() : nil;
    capture.forStack = self.stackActive;
    dispatch_async(self.ioQueue, ^{
        NSMutableArray<NSDictionary<NSString *, NSData *> *> *items = [NSMutableArray new];
        NSUInteger total = 0;
        for (NSDictionary<NSString *, id> *rawItem in raw) {
            NSMutableDictionary<NSString *, NSData *> *item = [NSMutableDictionary new];
            for (NSString *type in rawItem) {
                // Private markers such as the nspasteboard ones say how, not what.
                if ([type hasPrefix:@"org.nspasteboard."])
                    continue;
                NSData *data = DataForPasteboardValue(rawItem[type], type);
                if (data == nil)
                    continue;
                item[type] = data;
                total += data.length;
            }
            if (item.count > 0)
                [items addObject:item];
        }
        if (items.count == 0 || total > kMaxClipBytes)
            return;
        capture.items = items;
        [self ingestCapture:capture];
    });
}

// On the I/O queue: works out what the capture is, writes its files, then adds it
// on the main thread (or bumps the history item it duplicates).
- (void)ingestCapture:(ClipCapture *)capture {
    NSArray<NSDictionary<NSString *, NSData *> *> *items = capture.items;
    NSDictionary<NSString *, NSData *> *first = items.firstObject;
    ClipItem *item = [ClipItem new];
    item.identifier = NSUUID.UUID.UUIDString;
    item.createdAt = item.copiedAt = NSDate.date;
    item.source = capture.source;
    item.sourceDetail = capture.sourceDetail;
    item.pinboardID = capture.pinboardID;
    item.checksum = ChecksumOfItems(items);

    NSArray<NSURL *> *fileURLs = URLsInItems(items, UTTypeFileURL.identifier);
    NSData *imageData = ImageDataInItem(first);
    NSString *text = PlainTextInItem(first);
    NSAttributedString *rich = AttributedTextInItem(first);
    if (text == nil && rich != nil)
        text = rich.string;
    NSURL *url = URLsInItems(@[first], UTTypeURL.identifier).firstObject;

    UIImage *thumbnail = nil;
    if (fileURLs.count > 0) {
        item.kind = ClipKindFile;
        NSMutableArray<NSString *> *paths = [NSMutableArray new];
        for (NSURL *fileURL in fileURLs)
            [paths addObject:fileURL.path];
        item.text = [paths componentsJoinedByString:@"\n"];
    } else if (imageData != nil) {
        UIImage *image = [UIImage imageWithData:imageData];
        if (image == nil)
            return;
        item.kind = ClipKindImage;
        item.imageSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
        thumbnail = image;
    } else if (url != nil && ![url isFileURL]) {
        item.kind = ClipKindLink;
        item.text = url.absoluteString;
    } else if (text != nil) {
        item.text = text;
        if (ColorFromString(text) != nil) {
            item.kind = ClipKindColor;
            item.text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        } else if (LinkFromString(text) != nil) {
            item.kind = ClipKindLink;
            item.text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        } else {
            item.kind = ClipKindText;
            item.hasRichText = rich != nil;
        }
    } else {
        return; // nothing that can be shown or pasted as text
    }
    if (item.kind == ClipKindText && item.text.length == 0)
        return;
    item.looksLikeCode = item.kind == ClipKindText && !item.hasRichText &&
        TextLooksLikeCode(item.text);

    [self writeItems:items thumbnail:thumbnail forItem:item];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self addCapturedItem:item capture:capture];
    });
}

// On the I/O queue.
- (void)writeItems:(NSArray<NSDictionary<NSString *, NSData *> *> *)items thumbnail:(nullable UIImage *)thumbnail forItem:(ClipItem *)item {
    item.dataFile = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"plist"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToURL:[self dataURL:item.dataFile] options:NSDataWritingAtomic error:nil];
    if (thumbnail != nil) {
        item.thumbFile = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"img"];
        [ThumbnailData(thumbnail) writeToURL:[self thumbURL:item.thumbFile] options:NSDataWritingAtomic error:nil];
    }
}

- (void)addCapturedItem:(ClipItem *)item capture:(ClipCapture *)capture {
    ClipItem *result = item;
    if (item.pinboardID == nil) {
        ClipItem *existing = [self historyItemWithChecksum:item.checksum];
        if (existing != nil) {
            existing.copiedAt = NSDate.date;
            existing.source = item.source;
            existing.sourceDetail = item.sourceDetail;
            result = existing;
        } else {
            [self.items addObject:item];
        }
    } else {
        NSMutableArray<ClipItem *> *list = [[self itemsInPinboard:[self pinboardWithID:item.pinboardID]] mutableCopy];
        [list insertObject:item atIndex:MIN(capture.index, list.count)];
        [self.items addObject:item];
        [self renumber:list];
    }
    if (capture.forStack && self.stackActive) {
        [self.stack addObject:result];
        [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
    }
    if (capture.source != ClipSourceCreated && ClipboardPreferences.shared.soundEffects)
        AudioServicesPlaySystemSound(1104);
    [self pruneHistory];
    [self changed:nil];
    [self fetchLinkMetadataIfNeeded:result];
}

- (void)renumber:(NSArray<ClipItem *> *)list {
    [list enumerateObjectsUsingBlock:^(ClipItem *item, NSUInteger i, BOOL *stop) {
        item.order = i;
    }];
}

#pragma mark Link previews

- (void)fetchLinkMetadataIfNeeded:(ClipItem *)item {
    if (item.kind != ClipKindLink || item.linkFetched || !ClipboardPreferences.shared.linkPreviews)
        return;
    NSURL *url = item.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (url == nil || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
        return;
    if ([self.fetchingLinks containsObject:item.checksum])
        return;
    [self.fetchingLinks addObject:item.checksum];
    LPMetadataProvider *provider = [LPMetadataProvider new];
    provider.timeout = 15;
    NSString *checksum = item.checksum;
    [provider startFetchingMetadataForURL:url completionHandler:^(LPLinkMetadata *metadata, NSError *error) {
        void (^finish)(UIImage *) = ^(UIImage *image) {
            dispatch_async(self.ioQueue, ^{
                NSString *thumbFile = nil;
                if (image != nil) {
                    thumbFile = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"img"];
                    [ThumbnailData(image) writeToURL:[self thumbURL:thumbFile] options:NSDataWritingAtomic error:nil];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.fetchingLinks removeObject:checksum];
                    // Every copy of the link (history and pinboards) gets the preview.
                    NSMutableSet<NSString *> *updated = [NSMutableSet new];
                    for (ClipItem *other in self.items) {
                        if (![other.checksum isEqualToString:checksum])
                            continue;
                        other.linkFetched = YES;
                        if (metadata.title.length > 0)
                            other.linkTitle = metadata.title;
                        if (thumbFile != nil)
                            other.thumbFile = thumbFile;
                        [updated addObject:other.identifier];
                    }
                    [self changed:updated];
                });
            });
        };
        NSItemProvider *imageProvider = metadata.imageProvider ?: metadata.iconProvider;
        if (imageProvider != nil && [imageProvider canLoadObjectOfClass:UIImage.class]) {
            [imageProvider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *err) {
                finish([object isKindOfClass:UIImage.class] ? (UIImage *) object : nil);
            }];
        } else {
            finish(nil);
        }
    }];
}

#pragma mark Pausing

- (void)pauseFor:(NSTimeInterval)seconds {
    self.paused = YES;
    self.pausedUntil = seconds > 0 ? [NSDate dateWithTimeIntervalSinceNow:seconds] : nil;
    [self.resumeTimer invalidate];
    self.resumeTimer = nil;
    if (seconds > 0) {
        self.resumeTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
            [self resume];
        }];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardPauseDidChangeNotification object:self];
}

- (void)resume {
    [self.resumeTimer invalidate];
    self.resumeTimer = nil;
    self.pausedUntil = nil;
    if (!self.paused)
        return;
    self.paused = NO;
    // What was copied while paused stays out.
    [self setSeenChangeCount:UIPasteboard.generalPasteboard.changeCount];
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardPauseDidChangeNotification object:self];
}

#pragma mark Using items

- (NSString *)textForItems:(NSArray<ClipItem *> *)items {
    NSMutableArray<NSString *> *texts = [NSMutableArray new];
    for (ClipItem *item in items) {
        if (item.kind != ClipKindImage && item.text.length > 0)
            [texts addObject:item.text];
    }
    return texts.count > 0 ? [texts componentsJoinedByString:@"\n"] : nil;
}

- (void)copyItems:(NSArray<ClipItem *> *)items plainText:(BOOL)plainText {
    if (items.count == 0)
        return;
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    BOOL anyImage = NO;
    for (ClipItem *item in items)
        anyImage |= item.kind == ClipKindImage;
    if (plainText && !anyImage) {
        pasteboard.string = [self textForItems:items] ?: @"";
    } else {
        NSMutableArray<NSDictionary<NSString *, id> *> *pasteboardItems = [NSMutableArray new];
        for (ClipItem *item in items) {
            NSDictionary<NSString *, NSData *> *first = item.loadPasteboardItems.firstObject;
            if (first == nil)
                continue;
            NSMutableDictionary<NSString *, id> *converted = [NSMutableDictionary new];
            for (NSString *type in first) {
                if (plainText && [RichTextTypes() containsObject:type])
                    continue;
                converted[type] = PasteboardValueForData(first[type], type);
            }
            [pasteboardItems addObject:converted];
        }
        [pasteboard setItems:pasteboardItems options:@{}];
    }
    self.ownChangeCount = pasteboard.changeCount;
    [self setSeenChangeCount:pasteboard.changeCount];
    [self touchItems:items];
}

- (void)touchItems:(NSArray<ClipItem *> *)items {
    NSDate *now = NSDate.date;
    for (ClipItem *item in items) {
        ClipItem *history = item.pinboardID == nil ? item : [self historyItemWithChecksum:item.checksum];
        if (history == nil) {
            // A pinned item that is no longer in the history comes back to it.
            history = [item cloneWithNewIdentifier];
            history.pinboardID = nil;
            history.order = 0;
            [self.items addObject:history];
        }
        history.copiedAt = now;
        now = [now dateByAddingTimeInterval:-0.001]; // keep the selection's order
    }
    [self changed:nil];
}

#pragma mark Editing

- (void)registerUndoName:(NSString *)name block:(void (^)(ClipboardStore *store))block {
    [self.undoManager registerUndoWithTarget:self handler:block];
    [self.undoManager setActionName:name];
}

- (void)restoreItems:(NSArray<ClipItem *> *)items {
    [self.items addObjectsFromArray:items];
    [self registerUndoName:@"Add" block:^(ClipboardStore *store) {
        [store removeItems:items name:@"Delete"];
    }];
    [self changed:nil];
}

- (void)removeItems:(NSArray<ClipItem *> *)items name:(NSString *)name {
    NSSet<ClipItem *> *set = [NSSet setWithArray:items];
    NSMutableArray<ClipItem *> *removed = [NSMutableArray new];
    for (ClipItem *item in [self.items copy]) {
        if ([set containsObject:item]) {
            [self.items removeObject:item];
            [removed addObject:item];
        }
    }
    [self registerUndoName:name block:^(ClipboardStore *store) {
        [store restoreItems:removed];
    }];
    [self changed:nil];
}

- (ClipItem *)addText:(NSString *)text toPinboard:(ClipPinboard *)pinboard {
    ClipItem *item = [ClipItem new];
    item.identifier = NSUUID.UUID.UUIDString;
    item.createdAt = item.copiedAt = NSDate.date;
    item.source = ClipSourceCreated;
    item.pinboardID = pinboard.identifier;
    [self setText:text ofItem:item];
    if (pinboard != nil) {
        NSMutableArray<ClipItem *> *list = [[self itemsInPinboard:pinboard] mutableCopy];
        [list insertObject:item atIndex:0];
        [self renumber:list];
    }
    [self.items addObject:item];
    [self registerUndoName:@"New Item" block:^(ClipboardStore *store) {
        [store removeItems:@[item] name:@"New Item"];
    }];
    [self changed:nil];
    [self fetchLinkMetadataIfNeeded:item];
    return item;
}

// Replaces an item's contents with plain text, classifying it again.
- (void)setText:(NSString *)text ofItem:(ClipItem *)item {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableDictionary<NSString *, NSData *> *pasteboardItem = [NSMutableDictionary new];
    pasteboardItem[UTTypeUTF8PlainText.identifier] = [text dataUsingEncoding:NSUTF8StringEncoding];
    item.hasRichText = NO;
    item.thumbFile = nil;
    item.imageSize = CGSizeZero;
    if (ColorFromString(text) != nil) {
        item.kind = ClipKindColor;
        item.text = trimmed;
    } else if (LinkFromString(text) != nil) {
        item.kind = ClipKindLink;
        item.text = trimmed;
        pasteboardItem[UTTypeURL.identifier] = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        item.kind = ClipKindText;
        item.text = text;
    }
    item.linkTitle = nil;
    item.linkFetched = NO;
    item.looksLikeCode = item.kind == ClipKindText && TextLooksLikeCode(text);
    NSArray *items = @[pasteboardItem];
    item.checksum = ChecksumOfItems(items);
    item.dataFile = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"plist"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToURL:[self dataURL:item.dataFile] options:NSDataWritingAtomic error:nil];
}

- (void)addItemProviders:(NSArray<NSItemProvider *> *)providers toPinboard:(ClipPinboard *)pinboard
                 atIndex:(NSUInteger)index completion:(void (^)(void))completion {
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:providers.count];
    for (NSUInteger i = 0; i < providers.count; i++)
        [results addObject:NSNull.null];
    [providers enumerateObjectsUsingBlock:^(NSItemProvider *provider, NSUInteger i, BOOL *stop) {
        Class classes[] = {UIImage.class, NSURL.class, NSString.class};
        for (size_t c = 0; c < sizeof(classes) / sizeof(classes[0]); c++) {
            if (![provider canLoadObjectOfClass:classes[c]])
                continue;
            dispatch_group_enter(group);
            [provider loadObjectOfClass:classes[c] completionHandler:^(id object, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (object != nil)
                        results[i] = object;
                    dispatch_group_leave(group);
                });
            }];
            break;
        }
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSUInteger at = index;
        for (id object in results) {
            NSMutableDictionary<NSString *, NSData *> *item = [NSMutableDictionary new];
            if ([object isKindOfClass:UIImage.class]) {
                item[UTTypePNG.identifier] = UIImagePNGRepresentation(object);
            } else if ([object isKindOfClass:NSURL.class]) {
                NSURL *url = object;
                item[url.isFileURL ? UTTypeFileURL.identifier : UTTypeURL.identifier] = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
                item[UTTypeUTF8PlainText.identifier] = [(url.isFileURL ? url.path : url.absoluteString) dataUsingEncoding:NSUTF8StringEncoding];
            } else if ([object isKindOfClass:NSString.class]) {
                item[UTTypeUTF8PlainText.identifier] = [object dataUsingEncoding:NSUTF8StringEncoding];
            }
            if (item.count == 0 || item.allValues.firstObject == nil)
                continue;
            ClipCapture *capture = [ClipCapture new];
            capture.items = @[item];
            capture.source = ClipSourceCreated;
            capture.pinboardID = pinboard.identifier;
            capture.index = at++;
            dispatch_async(self.ioQueue, ^{
                [self ingestCapture:capture];
            });
        }
        if (completion != nil)
            dispatch_async(self.ioQueue, ^{
                dispatch_async(dispatch_get_main_queue(), completion);
            });
    });
}

- (NSArray<ClipItem *> *)pinItems:(NSArray<ClipItem *> *)items toPinboard:(ClipPinboard *)pinboard atIndex:(NSUInteger)index {
    NSMutableArray<ClipItem *> *list = [[self itemsInPinboard:pinboard] mutableCopy];
    NSMutableArray<ClipItem *> *pinned = [NSMutableArray new];
    for (ClipItem *item in items) {
        ClipItem *copy = [item cloneWithNewIdentifier];
        copy.pinboardID = pinboard.identifier;
        [pinned addObject:copy];
    }
    [list insertObjects:pinned atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(MIN(index, list.count), pinned.count)]];
    [self renumber:list];
    [self.items addObjectsFromArray:pinned];
    [self registerUndoName:@"Pin" block:^(ClipboardStore *store) {
        [store removeItems:pinned name:@"Pin"];
    }];
    [self changed:nil];
    return pinned;
}

- (void)deleteItems:(NSArray<ClipItem *> *)items {
    [self removeItems:items name:@"Delete"];
    // Deleted items also leave the stack.
    NSUInteger before = self.stack.count;
    [self.stack removeObjectsInArray:items];
    if (self.stack.count != before)
        [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
}

- (void)moveItem:(ClipItem *)item toIndex:(NSUInteger)index {
    ClipPinboard *pinboard = item.pinboardID ? [self pinboardWithID:item.pinboardID] : nil;
    if (pinboard == nil)
        return;
    NSMutableArray<ClipItem *> *list = [[self itemsInPinboard:pinboard] mutableCopy];
    NSUInteger from = [list indexOfObject:item];
    if (from == NSNotFound)
        return;
    [list removeObjectAtIndex:from];
    [list insertObject:item atIndex:MIN(index, list.count)];
    [self renumber:list];
    [self registerUndoName:@"Move" block:^(ClipboardStore *store) {
        [store moveItem:item toIndex:from];
    }];
    [self changed:nil];
}

// Edits go through a snapshot of the item's saved fields, which undo puts back.
- (void)editItem:(ClipItem *)item name:(NSString *)name change:(void (^)(void))change {
    NSDictionary *before = item.dictionaryRepresentation;
    change();
    [self registerUndoName:name block:^(ClipboardStore *store) {
        [store editItem:item name:name change:^{
            [item applyDictionary:before];
        }];
    }];
    [self changed:[NSSet setWithObject:item.identifier]];
}

- (void)renameItem:(ClipItem *)item title:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self editItem:item name:@"Rename" change:^{
        item.title = trimmed.length > 0 ? trimmed : nil;
    }];
}

- (void)updateItem:(ClipItem *)item text:(NSString *)text {
    [self editItem:item name:@"Edit" change:^{
        [self setText:text ofItem:item];
    }];
    [self fetchLinkMetadataIfNeeded:item];
}

- (void)updateItem:(ClipItem *)item attributedText:(NSAttributedString *)text {
    [self editItem:item name:@"Edit" change:^{
        NSRange all = NSMakeRange(0, text.length);
        NSData *rtf = [text dataFromRange:all documentAttributes:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType} error:nil];
        NSMutableDictionary<NSString *, NSData *> *pasteboardItem = [NSMutableDictionary new];
        pasteboardItem[UTTypeUTF8PlainText.identifier] = [text.string dataUsingEncoding:NSUTF8StringEncoding];
        if (rtf != nil)
            pasteboardItem[UTTypeRTF.identifier] = rtf;
        NSArray *items = @[pasteboardItem];
        item.kind = ClipKindText;
        item.text = text.string;
        item.hasRichText = rtf != nil;
        item.looksLikeCode = NO;
        item.checksum = ChecksumOfItems(items);
        item.dataFile = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"plist"];
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        [data writeToURL:[self dataURL:item.dataFile] options:NSDataWritingAtomic error:nil];
    }];
}

- (void)updateItem:(ClipItem *)item image:(UIImage *)image {
    NSData *png = UIImagePNGRepresentation(image);
    if (png == nil)
        return;
    [self editItem:item name:@"Edit" change:^{
        NSArray *items = @[@{UTTypePNG.identifier: png}];
        item.kind = ClipKindImage;
        item.imageSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
        item.checksum = ChecksumOfItems(items);
        [self writeItems:items thumbnail:image forItem:item];
    }];
}

- (void)updateItem:(ClipItem *)item color:(UIColor *)color {
    [self updateItem:item text:HexStringForColor(color)];
}

- (void)eraseHistory {
    [self removeItems:[self itemsInPinboard:nil] name:@"Erase History"];
}

#pragma mark Pinboards

- (NSInteger)suggestedColorIndex {
    NSCountedSet<NSNumber *> *used = [NSCountedSet new];
    for (ClipPinboard *pinboard in self.pinboardList)
        [used addObject:@(pinboard.colorIndex)];
    NSUInteger count = ClipPinboardColors().count;
    for (NSUInteger round = 0;; round++) {
        for (NSUInteger i = 0; i < count; i++) {
            if ([used countForObject:@(i)] <= round)
                return (NSInteger) i;
        }
    }
}

- (ClipPinboard *)createPinboardNamed:(NSString *)name colorIndex:(NSInteger)colorIndex {
    ClipPinboard *pinboard = [ClipPinboard new];
    pinboard.identifier = NSUUID.UUID.UUIDString;
    pinboard.name = name;
    pinboard.colorIndex = colorIndex;
    [self insertPinboard:pinboard atIndex:self.pinboardList.count items:@[]];
    return pinboard;
}

- (void)insertPinboard:(ClipPinboard *)pinboard atIndex:(NSUInteger)index items:(NSArray<ClipItem *> *)items {
    [self.pinboardList insertObject:pinboard atIndex:MIN(index, self.pinboardList.count)];
    [self.items addObjectsFromArray:items];
    [self registerUndoName:@"New Pinboard" block:^(ClipboardStore *store) {
        [store deletePinboard:pinboard];
    }];
    [self changed:nil];
}

- (void)renamePinboard:(ClipPinboard *)pinboard name:(NSString *)name {
    NSString *old = pinboard.name;
    pinboard.name = name;
    [self registerUndoName:@"Rename Pinboard" block:^(ClipboardStore *store) {
        [store renamePinboard:pinboard name:old];
    }];
    [self changed:nil];
}

- (void)setColorIndex:(NSInteger)colorIndex ofPinboard:(ClipPinboard *)pinboard {
    NSInteger old = pinboard.colorIndex;
    pinboard.colorIndex = colorIndex;
    [self registerUndoName:@"Pinboard Color" block:^(ClipboardStore *store) {
        [store setColorIndex:old ofPinboard:pinboard];
    }];
    [self changed:nil];
}

- (void)movePinboard:(ClipPinboard *)pinboard toIndex:(NSUInteger)index {
    NSUInteger from = [self.pinboardList indexOfObject:pinboard];
    if (from == NSNotFound)
        return;
    [self.pinboardList removeObjectAtIndex:from];
    [self.pinboardList insertObject:pinboard atIndex:MIN(index, self.pinboardList.count)];
    [self registerUndoName:@"Move Pinboard" block:^(ClipboardStore *store) {
        [store movePinboard:pinboard toIndex:from];
    }];
    [self changed:nil];
}

- (void)deletePinboard:(ClipPinboard *)pinboard {
    NSUInteger index = [self.pinboardList indexOfObject:pinboard];
    if (index == NSNotFound)
        return;
    NSArray<ClipItem *> *items = [self itemsInPinboard:pinboard];
    [self.pinboardList removeObjectAtIndex:index];
    [self.items removeObjectsInArray:items];
    [self registerUndoName:@"Delete Pinboard" block:^(ClipboardStore *store) {
        [store insertPinboard:pinboard atIndex:index items:items];
    }];
    [self changed:nil];
}

#pragma mark Paste Stack

- (void)setStackActive:(BOOL)stackActive {
    if (_stackActive == stackActive)
        return;
    _stackActive = stackActive;
    [self.stack removeAllObjects];
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
}

- (void)setStackReversed:(BOOL)stackReversed {
    _stackReversed = stackReversed;
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
}

- (NSArray<ClipItem *> *)stackItems {
    return self.stackReversed ? self.stack.reverseObjectEnumerator.allObjects : [self.stack copy];
}

- (ClipItem *)popStackItem {
    if (self.stack.count == 0)
        return nil;
    ClipItem *item = self.stackReversed ? self.stack.lastObject : self.stack.firstObject;
    [self.stack removeObject:item];
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
    return item;
}

- (void)removeStackItemAtIndex:(NSUInteger)index {
    NSArray<ClipItem *> *ordered = self.stackItems;
    if (index >= ordered.count)
        return;
    [self.stack removeObject:ordered[index]];
    [NSNotificationCenter.defaultCenter postNotificationName:ClipboardStackDidChangeNotification object:self];
}

@end
