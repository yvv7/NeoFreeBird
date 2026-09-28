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

@end

NS_ASSUME_NONNULL_END
