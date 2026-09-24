//
//  ClipboardStore.h
//  iSH
//
//  The clipboard manager's model: a history of everything copied while iSH is
//  running (or found on the pasteboard when it comes to the front), pinboards that
//  keep items for good, search, and the Paste Stack. Everything lives in one store
//  shared by all windows and is saved under Application Support/Clipboard.
//  Main thread only, except where noted.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ClipKind) {
    ClipKindText,
    ClipKindLink,
    ClipKindImage,
    ClipKindFile,
    ClipKindColor,
};

// Where a copy came from. iOS does not say which app copied something, so other
// apps are all one source.
typedef NS_ENUM(NSInteger, ClipSource) {
    ClipSourceOtherApp,
    ClipSourceTerminal, // selection copied in a terminal tab (or anything else iSH itself copied)
    ClipSourceLinux,    // written to /dev/clipboard
    ClipSourceCreated,  // made in the clipboard manager (new item, drop)
};

NSString *ClipKindName(ClipKind kind);
NSString *ClipKindSymbol(ClipKind kind);
NSString *ClipSourceName(ClipSource source);
NSString *ClipSourceSymbol(ClipSource source);

@interface ClipItem : NSObject

@property (readonly) NSString *identifier;
@property (readonly) ClipKind kind;
@property (readonly) NSDate *createdAt;
// When it was last copied; history is ordered by this, newest first.
@property (readonly) NSDate *copiedAt;
// Given by the user (Rename). nil means none.
@property (readonly, nullable) NSString *title;
// The plain text: for links the URL, for files their paths, for colors the hex value.
@property (readonly, nullable) NSString *text;
@property (readonly) BOOL hasRichText;
@property (readonly) ClipSource source;
// For copies made in iSH, the tab they were made in.
@property (readonly, nullable) NSString *sourceDetail;
// nil for history; otherwise the pinboard the item is pinned to.
@property (readonly, nullable) NSString *pinboardID;
@property (readonly) CGSize imageSize;
@property (readonly, nullable) NSString *linkTitle;

@property (readonly) BOOL looksLikeCode;
@property (readonly, nullable) UIColor *color;
@property (readonly, nullable) NSURL *URL; // links and the first file
// Title, else link title, else the first line of text.
@property (readonly) NSString *displayTitle;
// "65 characters", "2400 × 2400", the domain, …
@property (readonly, nullable) NSString *footnote;

// A small image for the card: the image itself, or a link's preview. Loaded
// lazily and cached; nil if there is none.
@property (readonly, nullable) UIImage *thumbnail;
// The full-size image for images (read from disk every time).
- (nullable UIImage *)loadImage;
- (nullable NSAttributedString *)loadAttributedText;
// What was on the pasteboard, type → data, as it can be put back.
- (NSArray<NSDictionary<NSString *, NSData *> *> *)loadPasteboardItems;

- (BOOL)matchesText:(NSString *)query;

@end

@interface ClipPinboard : NSObject
@property (readonly) NSString *identifier;
@property (readonly) NSString *name;
@property (readonly) NSInteger colorIndex;
@property (readonly) UIColor *color;
@end

// The colors a pinboard can have, in menu order.
NSArray<UIColor *> *ClipPinboardColors(void);
NSArray<NSString *> *ClipPinboardColorNames(void);

typedef NS_ENUM(NSInteger, ClipDateFilter) {
    ClipDateAny,
    ClipDateToday,
    ClipDateYesterday,
    ClipDateLastWeek,
    ClipDateLastMonth,
};
NSString *ClipDateFilterName(ClipDateFilter filter);

@interface ClipQuery : NSObject <NSCopying>
@property (copy) NSString *text;
@property (copy, nullable) NSSet<NSNumber *> *kinds;       // ClipKind; nil or empty means any
@property (copy, nullable) NSSet<NSNumber *> *sources;     // ClipSource
@property (copy, nullable) NSSet<NSString *> *pinboardIDs; // NSNull-free; @"" means history
@property ClipDateFilter date;
@property (readonly) BOOL isEmpty;
@end

typedef NS_ENUM(NSInteger, ClipRetention) {
    ClipRetentionDay,
    ClipRetentionWeek,
    ClipRetentionMonth,
    ClipRetentionYear,
    ClipRetentionForever,
};
NSString *ClipRetentionName(ClipRetention retention);

typedef NS_ENUM(NSInteger, ClipCardSize) {
    ClipCardSizeCompact,
    ClipCardSizeRegular,
    ClipCardSizeLarge,
};

// Settings, kept in user defaults.
@interface ClipboardPreferences : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL collectFromOtherApps; // read the pasteboard when iSH comes to the front
@property (nonatomic) BOOL pasteToClipboardOnly; // otherwise items are typed into the terminal
@property (nonatomic) BOOL alwaysPlainText;
@property (nonatomic) ClipRetention retention;
@property (nonatomic) ClipCardSize cardSize;
@property (nonatomic) BOOL ignoreConfidential;
@property (nonatomic) BOOL ignoreTransient;
@property (nonatomic) BOOL linkPreviews;
@property (nonatomic) BOOL soundEffects;
@end

// Posted when items or pinboards change. userInfo[ClipboardUpdatedItemsKey], when
// present, is the set of identifiers whose content changed (for redrawing cards);
// the lists themselves may have changed either way.
extern NSNotificationName const ClipboardStoreDidChangeNotification;
extern NSString *const ClipboardUpdatedItemsKey;
// Posted when the Paste Stack opens, closes or changes.
extern NSNotificationName const ClipboardStackDidChangeNotification;
// Posted when capture is paused or resumed.
extern NSNotificationName const ClipboardPauseDidChangeNotification;

@interface ClipboardStore : NSObject

+ (instancetype)shared;

// Loads saved items and starts watching the pasteboard. Called once at launch.
- (void)start;

// For attributing copies made inside iSH: returns the selected tab's title.
@property (copy, nullable) NSString *_Nullable (^currentTabTitle)(void);

#pragma mark Lists

@property (readonly) NSArray<ClipPinboard *> *pinboards;
- (nullable ClipPinboard *)pinboardWithID:(NSString *)identifier;
// History (pinboard nil) newest first, or a pinboard in its own order.
- (NSArray<ClipItem *> *)itemsInPinboard:(nullable ClipPinboard *)pinboard;
- (NSArray<ClipItem *> *)itemsMatchingQuery:(ClipQuery *)query;
- (nullable ClipItem *)itemWithID:(NSString *)identifier;
@property (readonly) NSUInteger historyCount;

#pragma mark Capture

@property (readonly) BOOL paused;
@property (readonly, nullable) NSDate *pausedUntil; // nil while paused means until resumed
- (void)pauseFor:(NSTimeInterval)seconds; // 0 means until resumed
- (void)resume;
// Reads the pasteboard now if it changed since it was last seen.
- (void)checkPasteboard;

#pragma mark Using items

// The text an item pastes as (joined with newlines for several).
- (nullable NSString *)textForItems:(NSArray<ClipItem *> *)items;
// Puts items on the system pasteboard. Copying moves them to the front of history.
- (void)copyItems:(NSArray<ClipItem *> *)items plainText:(BOOL)plainText;
// Marks items as just used, moving them to the front of history.
- (void)touchItems:(NSArray<ClipItem *> *)items;

#pragma mark Editing

@property (readonly) NSUndoManager *undoManager;

- (ClipItem *)addText:(NSString *)text toPinboard:(nullable ClipPinboard *)pinboard;
// Adds whatever the providers hold (from a drop). Completion runs on the main thread.
- (void)addItemProviders:(NSArray<NSItemProvider *> *)providers
              toPinboard:(nullable ClipPinboard *)pinboard
                 atIndex:(NSUInteger)index
              completion:(nullable void (^)(void))completion;
// Pinning copies: the history item stays where it is.
- (NSArray<ClipItem *> *)pinItems:(NSArray<ClipItem *> *)items
                      toPinboard:(ClipPinboard *)pinboard
                         atIndex:(NSUInteger)index;
// Deletes items, pinned or not. Undoable.
- (void)deleteItems:(NSArray<ClipItem *> *)items;
- (void)moveItem:(ClipItem *)item toIndex:(NSUInteger)index;
- (void)renameItem:(ClipItem *)item title:(nullable NSString *)title;
- (void)updateItem:(ClipItem *)item text:(NSString *)text;
- (void)updateItem:(ClipItem *)item attributedText:(NSAttributedString *)text;
- (void)updateItem:(ClipItem *)item image:(UIImage *)image;
- (void)updateItem:(ClipItem *)item color:(UIColor *)color;
- (void)eraseHistory;

- (ClipPinboard *)createPinboardNamed:(NSString *)name colorIndex:(NSInteger)colorIndex;
- (void)renamePinboard:(ClipPinboard *)pinboard name:(NSString *)name;
- (void)setColorIndex:(NSInteger)colorIndex ofPinboard:(ClipPinboard *)pinboard;
- (void)movePinboard:(ClipPinboard *)pinboard toIndex:(NSUInteger)index;
- (void)deletePinboard:(ClipPinboard *)pinboard;
// A color not used yet, for a new pinboard.
- (NSInteger)suggestedColorIndex;

#pragma mark Paste Stack

// While the stack is open, everything copied is also queued on it, and pasting
// takes items off it one by one.
@property (nonatomic) BOOL stackActive;
@property (readonly) NSArray<ClipItem *> *stackItems; // in pasting order
@property (nonatomic) BOOL stackReversed;
- (nullable ClipItem *)popStackItem;
- (void)removeStackItemAtIndex:(NSUInteger)index;

@end

// Called by /dev/clipboard after it writes the pasteboard, from any thread.
void ClipboardNoteLinuxWrite(void);

NS_ASSUME_NONNULL_END
