//
//  ClipboardUI.h
//  iSH
//
//  Building blocks shared by the clipboard manager's views: Liquid Glass surfaces
//  (with a blur fallback before iOS 26), the item card, the pinboard tab, and a
//  toast for confirming actions.
//

#import <UIKit/UIKit.h>
#import "ClipboardStore.h"

NS_ASSUME_NONNULL_BEGIN

// A glass surface with continuous corners. Content goes in contentView.
UIVisualEffectView *ClipGlassView(CGFloat cornerRadius);
void ClipSetCornerRadius(UIView *view, CGFloat radius);
// "now", "3m", "2h", "5d", "3w", or a date.
NSString *ClipShortRelativeTime(NSDate *date);
// Card side length for the current size preference.
CGFloat ClipCardSide(ClipCardSize size, UITraitCollection *traits);

// A short-lived glass capsule near the bottom of a view.
void ClipShowToast(UIView *view, NSString *text, NSString *_Nullable symbol);

@interface ClipCardCell : UICollectionViewCell
- (void)configureWithItem:(ClipItem *)item pinboard:(nullable ClipPinboard *)pinboard;
@property (nonatomic) BOOL cardSelected;
// 1–9 shows a ⌘-number hint; 0 hides it.
@property (nonatomic) NSInteger shortcutNumber;
@end

// A tab in the shelf's strip: the history or a pinboard.
@interface ClipTabCell : UICollectionViewCell
- (void)configureWithTitle:(NSString *)title color:(nullable UIColor *)color symbol:(nullable NSString *)symbol;
@property (nonatomic) BOOL tabSelected;
@property (nonatomic) BOOL dropTarget;
+ (CGSize)sizeForTitle:(NSString *)title hasIcon:(BOOL)hasIcon;
@end

NS_ASSUME_NONNULL_END
