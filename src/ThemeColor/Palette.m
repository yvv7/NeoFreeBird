//
//  Palette.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "ThemeColor/Palette.h"
#import "Core/BHTSettings.h"
#import <objc/runtime.h>

@protocol AEColorPalette <NSObject>
- (UIColor*)backgroundColor;
- (UIColor*)primaryColorForOption:(NSUInteger)option;
@end

@interface TAETwitterColorPaletteSettingInfo : NSObject
- (id<AEColorPalette>)colorPalette;
@end

@interface TAEColorSettings : NSObject
+ (instancetype)sharedSettings;
- (TAETwitterColorPaletteSettingInfo*)currentColorPalette;
@end

@implementation Palette

+ (TAETwitterColorPaletteSettingInfo*)currentPaletteInfo {
    Class settingsClass = objc_getClass("TAEColorSettings");
    if (![settingsClass respondsToSelector:@selector(sharedSettings)]) {
        return nil;
    }

    id settings = [settingsClass sharedSettings];
    if (![settings respondsToSelector:@selector(currentColorPalette)]) {
        return nil;
    }

    return [settings currentColorPalette];
}

+ (UIColor*)currentBackgroundColor {
    TAETwitterColorPaletteSettingInfo* info = [self currentPaletteInfo];
    if ([info respondsToSelector:@selector(colorPalette)]) {
        id<AEColorPalette> palette = [info colorPalette];
        if ([palette respondsToSelector:@selector(backgroundColor)]) {
            UIColor* background = [palette backgroundColor];
            if (background) {
                return background;
            }
        }
    }
    return [UIColor systemBackgroundColor];
}

+ (UIColor*)currentAccentColor {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSInteger option = [defaults objectForKey:@"bh_color_theme_selectedColor"] ?
        [defaults integerForKey:@"bh_color_theme_selectedColor"] :
        [defaults integerForKey:@"T1ColorSettingsPrimaryColorOptionKey"];
    if (option < 1) {
        option = 1;
    }

    TAETwitterColorPaletteSettingInfo* info = [self currentPaletteInfo];
    if ([info respondsToSelector:@selector(colorPalette)]) {
        id<AEColorPalette> palette = [info colorPalette];
        if ([palette respondsToSelector:@selector(primaryColorForOption:)]) {
            UIColor* color = [palette primaryColorForOption:option];
            if ([color isKindOfClass:[UIColor class]]) {
                return color;
            }
        }
    }
    // Fallback: classic Twitter blue
    return [UIColor colorWithRed:29.0/255.0 green:155.0/255.0 blue:240.0/255.0 alpha:1.0];
}

+ (UIColor*)currentCardBackgroundColor {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            if ([BHTSettings boolForKey:@"enable_dim_theme"]) {
                return [UIColor colorWithRed:30.0/255.0 green:39.0/255.0 blue:50.0/255.0 alpha:1.0];
            }
            return [UIColor colorWithRed:22.0/255.0 green:24.0/255.0 blue:28.0/255.0 alpha:1.0];
        }
        return [UIColor colorWithRed:255.0/255.0 green:255.0/255.0 blue:255.0/255.0 alpha:1.0];
    }];
}

@end

