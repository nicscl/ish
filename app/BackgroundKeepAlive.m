//
//  BackgroundKeepAlive.m
//  iSH
//

#import <CoreLocation/CoreLocation.h>
#import "BackgroundKeepAlive.h"

static NSString *const kKeepAliveEnabled = @"Keep Alive in Background";

@interface BackgroundKeepAlive () <CLLocationManagerDelegate>
@property CLLocationManager *manager;
@end

@implementation BackgroundKeepAlive

+ (instancetype)shared {
    static BackgroundKeepAlive *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [BackgroundKeepAlive new];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _enabled = [NSUserDefaults.standardUserDefaults boolForKey:kKeepAliveEnabled];
        self.manager = [CLLocationManager new];
        self.manager.delegate = self;
        self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
        self.manager.distanceFilter = kCLDistanceFilterNone;
        // The default lets iOS pause updates when the device sits still, and a
        // paused app gets suspended like any other.
        self.manager.pausesLocationUpdatesAutomatically = NO;
        self.manager.activityType = CLActivityTypeOther;
        [self update];
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kKeepAliveEnabled];
    [self update];
}

- (BOOL)denied {
    CLAuthorizationStatus status = self.manager.authorizationStatus;
    return status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted;
}

- (void)update {
    if (!self.enabled) {
        [self.manager stopUpdatingLocation];
        self.manager.allowsBackgroundLocationUpdates = NO;
        return;
    }
    switch (self.manager.authorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            [self.manager requestAlwaysAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            self.manager.allowsBackgroundLocationUpdates = YES;
            // Needed for background updates under When In Use; shows the location pill.
            self.manager.showsBackgroundLocationIndicator = YES;
            [self.manager startUpdatingLocation];
            break;
        default:
            break;
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self update];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"keep alive: location failed %@", error);
}

@end
