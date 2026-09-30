//
//  NFBProgressPill.h
//  NeoFreeBird
//
//  Pill-style download progress at the top of the screen.
//

@import UIKit;

NS_ASSUME_NONNULL_BEGIN

@interface NFBProgressPill : NSObject

// Show a progress pill. Returns a token to update/dismiss it.
+ (instancetype)showWithTitle:(NSString*)title;

// Update title smoothly (e.g. "Downloading 2 of 9").
- (void)updateTitle:(NSString*)title;

// Update progress (0.0 to 1.0) and optional detail text.
- (void)setProgress:(CGFloat)progress detail:(NSString* _Nullable)detail;

// Dismiss with a completion message (shows "✓ Saved" briefly).
- (void)dismissWithMessage:(NSString*)message;

// Dismiss immediately.
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
