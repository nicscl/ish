//
//  BackgroundKeepAlive.h
//  iSH
//
//  Keeps iSH running while it is in the background, so ssh sessions, sshd and
//  anything else inside it stay alive. iOS suspends ordinary apps shortly after
//  they leave the foreground; an app receiving location updates in the
//  background is not suspended. Updates are requested at the coarsest accuracy
//  (cell and Wi-Fi, no GPS) and never paused, so the cost is low.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BackgroundKeepAlive : NSObject

+ (instancetype)shared;

// Persisted; restored at launch.
@property (nonatomic) BOOL enabled;
// Location access was refused, so enabling it has no effect until it is granted in Settings.
@property (readonly) BOOL denied;

@end

NS_ASSUME_NONNULL_END
