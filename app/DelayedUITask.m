//
//  DelayedUITask.m
//  iSH
//
//  Created by Theodore Dubois on 11/8/17.
//

#import "DelayedUITask.h"

@interface DelayedUITask ()

@property (weak) id target;
@property SEL action;
@property NSTimer *timer;

@end

@implementation DelayedUITask

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if (self = [super init]) {
        self.target = target;
        self.action = action;
    }
    return self;
}

- (void)schedule {
    // NSRunLoop is not thread safe, and schedule is called from the emulator thread.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self schedule];
        });
        return;
    }
    if (self.timer.valid)
        return;
    __weak DelayedUITask *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1./60 repeats:NO block:^(NSTimer * _Nonnull timer) {
        DelayedUITask *self = weakSelf;
        if (self == nil)
            return;
        self.timer = nil;
        id target = self.target;
        if (target == nil)
            return;
        ((void (*)(id, SEL)) [target methodForSelector:self.action])(target, self.action);
    }];
    // Common modes so that output keeps draining while the user is scrolling or dragging.
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"cancel is main thread only");
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc {
    [self cancel];
}

@end
