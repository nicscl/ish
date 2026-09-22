//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"

TerminalViewController *currentTerminalViewController = NULL;

// Restoration activity keys. TerminalUUID is the selected tab and what versions
// without tabs stored; TerminalUUIDs is the ordered list of all tabs.
NSString *const SceneActivityType = @"app.ish.scene";
NSString *const SceneTerminalUUIDKey = @"TerminalUUID";
NSString *const SceneTerminalUUIDsKey = @"TerminalUUIDs";

NSArray<TerminalViewController *> *ConnectedTerminalViewControllers(void) {
    NSMutableArray<TerminalViewController *> *controllers = [NSMutableArray new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *) scene).windows) {
            if ([window.rootViewController isKindOfClass:TerminalViewController.class])
                [controllers addObject:(TerminalViewController *) window.rootViewController];
        }
    }
    return controllers;
}

NSArray<NSUUID *> *SceneTerminalUUIDs(NSUserActivity *activity) {
    NSMutableArray<NSUUID *> *uuids = [NSMutableArray new];
    NSArray *strings = activity.userInfo[SceneTerminalUUIDsKey];
    if (![strings isKindOfClass:NSArray.class])
        strings = @[];
    NSString *selected = activity.userInfo[SceneTerminalUUIDKey];
    if ([selected isKindOfClass:NSString.class] && ![strings containsObject:selected])
        strings = [@[selected] arrayByAddingObjectsFromArray:strings];
    for (NSString *string in strings) {
        NSUUID *uuid = [string isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:string] : nil;
        if (uuid != nil)
            [uuids addObject:uuid];
    }
    return uuids;
}

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
        return;
    }

    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    vc.sceneSession = session;
    NSUserActivity *activity = session.stateRestorationActivity;
    if (activity == nil) {
        // A window opened by "Move Tab to New Window" brings its tab along.
        for (NSUserActivity *requested in connectionOptions.userActivities) {
            if ([requested.activityType isEqualToString:SceneActivityType])
                activity = requested;
        }
    }
    if (activity == nil) {
        [vc startNewSession];
    } else {
        NSString *selected = activity.userInfo[SceneTerminalUUIDKey];
        [vc reconnectSessionsFromTerminalUUIDs:SceneTerminalUUIDs(activity)
                                      selected:[selected isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:selected] : nil];
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:SceneActivityType];
    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if ([vc isKindOfClass:TerminalViewController.class]) {
        NSMutableArray<NSString *> *uuids = [NSMutableArray new];
        for (NSUUID *uuid in vc.tabTerminalUUIDs)
            [uuids addObject:uuid.UUIDString];
        NSString *selected = vc.sessionTerminalUUID.UUIDString;
        if (selected != nil)
            [activity addUserInfoEntriesFromDictionary:@{SceneTerminalUUIDKey: selected}];
        [activity addUserInfoEntriesFromDictionary:@{SceneTerminalUUIDsKey: uuids}];
    }
    return activity;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;;
    currentTerminalViewController = terminalViewController;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;

    if (currentTerminalViewController == terminalViewController) {
        currentTerminalViewController = NULL;
    }
}

@end
