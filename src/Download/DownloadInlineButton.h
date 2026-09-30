//
//  DownloadInlineButton.h
//  NeoFreeBird
//
//  Original author: BandarHelal at 09/04/2022
//  Modified by: actuallyaridan at 27/04/2025
//

@import UIKit;
#import "Core/BHTManager.h"

NS_ASSUME_NONNULL_BEGIN

// Presents the download quality/options sheet for a tweet's media. Formerly an
// inline action-bar button; now driven from the tweet overflow (3-dot) menu.
@interface DownloadInlineButton : NSObject

- (void)presentDownloadOptionsForMediaEntities:(NSArray*)mediaEntities
                                         status:(id)status;

// Direct single-URL download (used by the immersive player's in-video
// download button, where we have the playing URL but no media entities).
- (void)downloadVideoAtURL:(NSURL*)url;

// Same, with a smart filename base (e.g. "username_20250101_120000").
// Pass nil for a random UUID filename.
- (void)downloadVideoAtURL:(NSURL*)url fileNameBase:(NSString* _Nullable)base;

// Download a UIImage (from the immersive image viewer).
- (void)downloadImage:(UIImage*)image fileNameBase:(NSString* _Nullable)base;
- (void)downloadImages:(NSArray<UIImage*>*)images fileNameBase:(NSString* _Nullable)base;

// Download images from URLs (from the tweet 3-dots menu).
- (void)downloadImageURLs:(NSArray<NSURL*>*)urls fileNameBase:(NSString* _Nullable)base;

// Get a smart filename base for a status (username_date).
- (NSString* _Nullable)fileBaseForStatus:(id)status;

@end

NS_ASSUME_NONNULL_END
