//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Settings/Pages/CountryFilterViewController.h"
#import "Headers/TWHeaders.h"

extern void applyHideCustomTimelinesSetting(void);

@implementation TimelinesSettingsViewController

- (NSString*)pageKey {
    return @"timelines";
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    }
}

#pragma mark - Sub-page Navigation

- (void)showCountryFilterViewController:(NSDictionary*)sender {
    CountryFilterViewController* vc = [[CountryFilterViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
