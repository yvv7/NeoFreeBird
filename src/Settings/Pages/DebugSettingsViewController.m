//
//  DebugSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/DebugSettingsViewController.h"
#import "Settings/Pages/DiagnosticsViewController.h"
#import "Headers/TWHeaders.h"
#import "Core/BHTBundle.h"

@implementation DebugSettingsViewController

- (NSString*)pageKey {
    return @"debug";
}

- (void)buildSettingsList {
    [super buildSettingsList];
    // Append a "View Diagnostics" button row.
    NSDictionary* diagnosticsButton = @{
        @"type": @"button",
        @"title": [[BHTBundle sharedBundle]
            localizedStringForKey:@"DIAGNOSTICS_TITLE"] ?: @"Diagnostics",
        @"subtitle": [[BHTBundle sharedBundle]
            localizedStringForKey:@"DIAGNOSTICS_SUBTITLE"]
            ?: @"View the tweak's diagnostic log",
        @"action": @"showDiagnostics",
    };
    self.toggles = [self.toggles arrayByAddingObject:diagnosticsButton];
    [self updateVisibleToggles];
}

- (void)showDiagnostics:(NSDictionary*)data {
    (void)data;
    DiagnosticsViewController* vc =
        [[DiagnosticsViewController alloc] initWithAccount:self.account];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"flex_twitter"]) {
        if (sender.isOn) {
            [[objc_getClass("FLEXManager") sharedManager] showExplorer];
        } else {
            [[objc_getClass("FLEXManager") sharedManager] hideExplorer];
        }
    }
}

@end
