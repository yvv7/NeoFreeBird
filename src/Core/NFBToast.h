//
//  NFBToast.h
//  NeoFreeBird
//
//  Pill-style toast notification at the top of the screen.
//

@import UIKit;

NS_ASSUME_NONNULL_BEGIN

@interface NFBToast : NSObject

// Show a pill toast with the given message. Auto-dismisses after 2s.
+ (void)show:(NSString*)message;

// Show with a custom duration.
+ (void)show:(NSString*)message duration:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END
