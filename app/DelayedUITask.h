//
//  DelayedUITask.h
//  iSH
//
//  Created by Theodore Dubois on 11/8/17.
//

#import <Foundation/Foundation.h>

// Coalesces repeated schedule calls into a single main-thread invocation of
// target's action on the next frame. The target is held weakly so that the
// owner of the task (typically also the target) can be deallocated.
@interface DelayedUITask : NSObject

- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)schedule;
- (void)cancel;

@end
