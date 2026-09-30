//
//  Palette.h
//  NeoFreeBird
//
//  Created by nyaathea
//

#import <UIKit/UIKit.h>

@interface Palette : NSObject

/**
 * Twitter's current app background color, read straight from the active
 * TAEColorPalette so it always matches the app chrome.
 */
+ (UIColor*)currentBackgroundColor;

/**
 * Current primary accent color (Twitter blue, or user-selected theme color).
 */
+ (UIColor*)currentAccentColor;

/**
 * Modern card background color for Inset Grouped table cells and modals.
 */
+ (UIColor*)currentCardBackgroundColor;

@end

