//
//  DownloadInlineButton.m
//  NeoFreeBird
//
//  Original author: BandarHelal at 09/04/2022
//  Modified by: actuallyaridan at 27/04/2025
//

#import "Download/DownloadInlineButton.h"
#import <objc/runtime.h>
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"

#pragma mark - Helpers
static UIWindow* KeyWindow(void) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow)
                return window;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController* TopMostController(void) {
    UIViewController* top = KeyWindow().rootViewController;
    while (top.presentedViewController)
        top = top.presentedViewController;
    return top;
}

#pragma mark - DownloadInlineButton
@interface DownloadInlineButton ()
@property (nonatomic, strong) TFNHUD* hud;
@end

@implementation DownloadInlineButton

#pragma mark - Download handler
- (void)presentDownloadOptionsForMediaEntities:(NSArray*)mediaEntities {
    @try {
        NSAttributedString* titleString = [[NSAttributedString alloc]
            initWithString:[[BHTBundle sharedBundle]
                               localizedStringForKey:@"DOWNLOAD_MENU_TITLE"]
                attributes:@{
                    NSFontAttributeName: [BHTManager menuTitleFont],
                    NSForegroundColorAttributeName: UIColor.labelColor
                }];
        TFNActiveTextItem* title = [[objc_getClass("TFNActiveTextItem") alloc]
            initWithTextModel:[[objc_getClass("TFNAttributedTextModel") alloc]
                                  initWithAttributedString:titleString]
                 activeRanges:nil];

        void (^showHUD)(NSString*) = ^(NSString* text) {
            self.hud = [[objc_getClass("TFNHUD") alloc] initWithText:text];
            [self.hud show];
        };
        void (^dismissHUD)(void) = ^{
            [self.hud hide];
        };

        // Every download runs through FFmpeg: plain mp4s are stream-copied,
        // GIFs are palette-encoded, HLS-only resolutions are re-encoded with
        // VideoToolbox. The output path is appended to args; progress comes
        // from the processed time measured against the probed duration.
        NSString* downloadingText = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"];
        void (^ffmpegDownload)(NSString*, NSString*, double) = ^(
            NSString* args, NSString* ext, double durationMs) {
            showHUD(downloadingText);
            NSURL* outFile = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                URLByAppendingPathComponent:[NSString
                                                stringWithFormat:@"%@.%@",
                                                                 NSUUID.UUID
                                                                     .UUIDString,
                                                                 ext]];
            // Quote the output path and retry once on failure: X's media URLs
            // are signed and can briefly 403/timeout, so a single ffmpeg
            // attempt makes downloads flaky. -y lets the retry overwrite the
            // partial file left behind by the first attempt.
            NSString* command =
                [NSString stringWithFormat:@"%@ -y \"%@\"", args, outFile.path];

            __block void (^runAttempt)(void);
            __block NSInteger attempt = 0;
            runAttempt = ^{
                attempt++;
                [FFmpegKit
                    executeAsync:command
                    withCompleteCallback:^(FFmpegSession* session) {
                        ReturnCode* returnCode = [session getReturnCode];
                        if (![ReturnCode isSuccess:returnCode] && attempt < 2) {
                            NSLog(@"[NFB] Download attempt %ld failed (rc=%@), "
                                  @"retrying: %@",
                                  (long)attempt,
                                  returnCode
                                      ? [NSString
                                            stringWithFormat:@"%d",
                                                             [returnCode getValue]]
                                      : @"n/a",
                                  [session getCommand]);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self.hud setText:downloadingText];
                            });
                            runAttempt();
                            return;
                        }
                        runAttempt = nil;  // break the self-retain cycle
                        dispatch_async(dispatch_get_main_queue(), ^{
                            dismissHUD();
                            UINotificationFeedbackGenerator* feedback =
                                [UINotificationFeedbackGenerator new];
                            [feedback prepare];

                            if ([ReturnCode isSuccess:returnCode]) {
                                if (![BHTSettings boolForKey:@"direct_save"]) {
                                    [BHTManager showSaveVC:outFile];
                                } else {
                                    [feedback
                                        notificationOccurred:
                                            UINotificationFeedbackTypeSuccess];
                                    if ([ext isEqualToString:@"gif"])
                                        [BHTManager saveGIF:outFile];
                                    else
                                        [BHTManager save:outFile];
                                }
                            } else {
                                [feedback
                                    notificationOccurred:
                                        UINotificationFeedbackTypeError];
                                NSString* rcString =
                                    returnCode
                                        ? [NSString
                                              stringWithFormat:@"%d",
                                                               [returnCode getValue]]
                                        : @"n/a";
                                NSString* failTrace =
                                    [session getFailStackTrace] ?: @"";
                                if (failTrace.length == 0)
                                    failTrace = [session getOutput] ?: @"";
                                NSString* failedFormat = [[BHTBundle sharedBundle]
                                    localizedStringForKey:@"DOWNLOAD_FAILED_MESSAGE"];
                                if ([failedFormat
                                        isEqualToString:@"DOWNLOAD_FAILED_MESSAGE"]) {
                                    failedFormat = @"Download failed (code %@).";
                                }
                                [self
                                    presentFailureAlertWithMessage:
                                        [NSString stringWithFormat:failedFormat, rcString]
                                                          command:[session getCommand]
                                                        failTrace:failTrace];
                            }
                        });
                    }
                    withLogCallback:nil
                withStatisticsCallback:^(Statistics* statistics) {
                    NSString* detail;
                    if (durationMs > 0) {
                        detail = [BHTManager
                            getDownloadingPercent:MIN([statistics getTime] / durationMs,
                                                      1.0)];
                    } else if ([statistics getSize] > 0) {
                        detail = [NSByteCountFormatter
                            stringFromByteCount:[statistics getSize]
                                     countStyle:NSByteCountFormatterCountStyleFile];
                    } else {
                        return;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.hud
                            setText:[NSString stringWithFormat:@"%@ %@", downloadingText,
                                                               detail]];
                    });
                }];
            };
        };

        // Variant builders
        TFNActionItem* (^makeMP4Item)(NSURL*, double, NSString*) =
            ^TFNActionItem*(NSURL* url, double durationMs, NSString* itemTitle) {
                return [objc_getClass("TFNActionItem")
                    actionItemWithTitle:itemTitle
                              imageName:@"arrow_down_circle_stroke"
                                 action:^{
                                     ffmpegDownload(
                                         [NSString stringWithFormat:@"-i \"%@\" -c copy",
                                                                    url.absoluteString],
                                         @"mp4", durationMs);
                                 }];
            };

        TFNActionItem* (^makeGIFItem)(NSURL*, double) = ^TFNActionItem*(
            NSURL* url, double durationMs) {
            return [objc_getClass("TFNActionItem")
                actionItemWithTitle:
                    [[BHTBundle sharedBundle]
                        localizedStringForKey:@"DOWNLOAD_AS_GIF_OPTION_TITLE"]
                          imageName:@"arrow_down_circle_stroke"
                             action:^{
                                 ffmpegDownload(
                                     [NSString
                                         stringWithFormat:@"-i \"%@\" -an -vf "
                                                          @"split[a][b];[a]palettegen["
                                                          @"p];[b][p]paletteuse",
                                                          url.absoluteString],
                                     @"gif", durationMs);
                             }];
        };

        TFNActionItem* (^makeHLSItem)(NSURL*, NSString*, double) = ^TFNActionItem*(
            NSURL* url, NSString* resolution, double durationMs) {
            return [objc_getClass("TFNActionItem")
                actionItemWithTitle:resolution
                          imageName:@"arrow_down_circle_stroke"
                             action:^{
                                 ffmpegDownload(
                                     [NSString
                                         stringWithFormat:
                                             @"-i \"%@\" -vf scale=%@:flags=lanczos -c:v "
                                             @"h264_videotoolbox -b:v 2M -c:a copy",
                                             url.absoluteString, resolution],
                                     @"mp4", durationMs);
                             }];
        };

        // videoInfo.variants backs both video (mediaType 3) and GIF (mediaType 2);
        // photos carry no videoInfo. Probing the playlist supplies the duration
        // for progress and any HLS-only resolutions, so every quality is offered
        // in a single sheet. mp4 variants win when both carry the same
        // resolution; media without a playlist (GIFs) skips the probe entirely.
        void (^buildVariantItems)(TFSTwitterEntityMedia*, void (^)(NSArray*)) = ^(
            TFSTwitterEntityMedia* media, void (^done)(NSArray*)) {
            NSMutableArray<NSURL*>* mp4URLs = [NSMutableArray new];
            NSURL* m3u8URL = nil;
            for (TFSTwitterEntityMediaVideoVariant* variant in media.videoInfo
                     .variants) {
                NSURL* url =
                    variant.url.length ? [NSURL URLWithString:variant.url] : nil;
                if (!url)
                    continue;

                if ([variant.contentType isEqualToString:@"video/mp4"])
                    [mp4URLs addObject:url];
                else if ([variant.contentType
                             isEqualToString:@"application/x-mpegURL"] &&
                         !m3u8URL)
                    m3u8URL = url;
            }

            if ([BHTSettings boolForKey:@"download_highest_quality"] &&
                media.mediaType == 3 && mp4URLs.count > 0) {
                NSURL* bestURL = mp4URLs.firstObject;
                NSInteger bestPixels = -1;
                for (NSURL* url in mp4URLs) {
                    NSArray<NSString*>* dims =
                        [[BHTManager getVideoQuality:url.absoluteString]
                            componentsSeparatedByString:@"x"];
                    NSInteger pixels = dims.count == 2
                                           ? dims[0].integerValue * dims[1].integerValue
                                           : 0;
                    if (pixels > bestPixels) {
                        bestPixels = pixels;
                        bestURL = url;
                    }
                }
                ffmpegDownload(
                    [NSString stringWithFormat:@"-i \"%@\" -c copy", bestURL.absoluteString],
                    @"mp4", 0);
                return;
            }

            NSMutableArray* items = [NSMutableArray new];
            NSMutableSet<NSString*>* offered = [NSMutableSet new];
            void (^appendMP4Items)(double) = ^(double durationMs) {
                BOOL isGIF = media.mediaType == 2;
                for (NSURL* url in mp4URLs) {
                    NSString* itemTitle =
                        isGIF ? [[BHTBundle sharedBundle]
                                    localizedStringForKey:@"DOWNLOAD_AS_MP4_OPTION_TITLE"]
                              : [BHTManager getVideoQuality:url.absoluteString];
                    [offered addObject:[BHTManager getVideoQuality:url.absoluteString]];
                    [items addObject:makeMP4Item(url, durationMs, itemTitle)];
                    if (isGIF)
                        [items addObject:makeGIFItem(url, durationMs)];
                }
            };

            if (!m3u8URL) {
                appendMP4Items(0);
                done(items);
                return;
            }

            showHUD([[BHTBundle sharedBundle]
                localizedStringForKey:@"FETCHING_PROGRESS_TITLE"]);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                MediaInformation* info = [BHTManager getM3U8Information:m3u8URL];
                double durationMs = [info getDuration].doubleValue * 1000.0;

                dispatch_async(dispatch_get_main_queue(), ^{
                    dismissHUD();
                    appendMP4Items(durationMs);
                    for (StreamInformation* stream in [info getStreams]) {
                        NSNumber* width = [stream getWidth];
                        NSNumber* height = [stream getHeight];
                        if (width == nil || height == nil)
                            continue;

                        NSString* resolution =
                            [NSString stringWithFormat:@"%@x%@", width, height];
                        if ([offered containsObject:resolution])
                            continue;

                        [offered addObject:resolution];
                        [items addObject:makeHLSItem(m3u8URL, resolution, durationMs)];
                    }
                    done(items);
                });
            });
        };

        // Filter to video/GIF so grouping keys off the real video count, not the
        // raw media count.
        NSMutableArray<TFSTwitterEntityMedia*>* videoEntities =
            [NSMutableArray new];
        for (TFSTwitterEntityMedia* media in mediaEntities) {
            if ((media.mediaType == 2 || media.mediaType == 3) &&
                media.videoInfo.variants.count > 0) {
                [videoEntities addObject:media];
            }
        }

        void (^presentSheet)(NSArray*) = ^(NSArray* items) {
            NSMutableArray* actions = [NSMutableArray arrayWithObject:title];
            [actions addObjectsFromArray:items];

            TFNMenuSheetViewController* sheet =
                [[objc_getClass("TFNMenuSheetViewController") alloc]
                    initWithActionItems:actions.copy];
            [sheet tfnPresentedCustomPresentFromViewController:TopMostController()
                                                      animated:YES
                                                    completion:nil];
        };

        if (videoEntities.count > 1) {
            NSMutableArray* groups = [NSMutableArray new];
            NSString* downloadAllTitle =
                [[BHTBundle sharedBundle] localizedStringForKey:@"DOWNLOAD_ALL_TITLE"];
            if ([downloadAllTitle isEqualToString:@"DOWNLOAD_ALL_TITLE"])
                downloadAllTitle = @"Download all (highest quality)";
            [groups addObject:[objc_getClass("TFNActionItem")
                                  actionItemWithTitle:downloadAllTitle
                                            imageName:@"arrow_down_circle_stroke"
                                               action:^{
                                                   [self downloadAllVideosAtHighestQuality:
                                                             videoEntities];
                                               }]];
            [videoEntities enumerateObjectsUsingBlock:^(TFSTwitterEntityMedia* media,
                                                        NSUInteger idx, BOOL* stop) {
                [groups
                    addObject:[objc_getClass("TFNActionItem")
                                  actionItemWithTitle:
                                      [NSString
                                          stringWithFormat:
                                              [[BHTBundle sharedBundle]
                                                  localizedStringForKey:
                                                      @"DOWNLOAD_VIDEO_NUMBER_TITLE"],
                                              (unsigned long)idx + 1]
                                            imageName:@"arrow_down_circle_stroke"
                                               action:^{
                                                   buildVariantItems(media, presentSheet);
                                               }]];
            }];
            presentSheet(groups);
        } else {
            buildVariantItems(videoEntities.firstObject, presentSheet);
        }
    } @catch (__unused NSException* ex) {
        UIAlertController* alert = [UIAlertController
            alertControllerWithTitle:
                [[BHTBundle sharedBundle]
                    localizedTwitterStringForKey:@"ERROR_ALERT_TITLE"]
                             message:[[BHTBundle sharedBundle]
                                         localizedStringForKey:@"UNKNOWN_ERROR"]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
                             actionWithTitle:[[BHTBundle sharedBundle]
                                                 localizedTwitterStringForKey:
                                                     @"OK_ACTION_LABEL"]
                                       style:UIAlertActionStyleDefault
                                     handler:nil]];
        [TopMostController() presentViewController:alert
                                          animated:YES
                                        completion:nil];
    }
}

#pragma mark - Download failure alert
// Shared by the single and bulk download paths: logs the full ffmpeg
// diagnostics, shows the tail in an alert, and offers the full trace on the
// clipboard via "Copy details".
- (void)presentFailureAlertWithMessage:(NSString*)message
                               command:(NSString*)command
                             failTrace:(NSString*)failTrace {
    NSLog(@"[NFB] %@ command=%@\n%@", message, command, failTrace);

    // Keep the alert readable: tail of the trace on screen, full trace in
    // the log and on the clipboard.
    NSString* shortTrace = failTrace;
    if (shortTrace.length > 600) {
        shortTrace = [shortTrace substringFromIndex:shortTrace.length - 600];
    }
    NSString* copyLabel =
        [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_DETAILS_ACTION_LABEL"];
    if ([copyLabel isEqualToString:@"COPY_DETAILS_ACTION_LABEL"]) {
        copyLabel = @"Copy details";
    }
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[[BHTBundle sharedBundle]
                                     localizedTwitterStringForKey:@"ERROR_ALERT_TITLE"]
                         message:[NSString stringWithFormat:@"%@\n\n%@",
                                                            message, shortTrace]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:copyLabel
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction* _) {
                                               UIPasteboard.generalPasteboard.string =
                                                   [NSString
                                                       stringWithFormat:
                                                           @"NeoFreeBird download "
                                                           @"failure\n%@\nCommand: "
                                                           @"%@\n\n%@",
                                                           message, command, failTrace];
                                           }]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:[[BHTBundle sharedBundle]
                                             localizedTwitterStringForKey:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:nil]];
    [TopMostController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Bulk download
// Picks the highest-quality mp4 variant for a media entity, mirroring the
// download_highest_quality logic.
static NSURL* _Nullable BestMP4URLForMedia(TFSTwitterEntityMedia* media) {
    NSURL* bestURL = nil;
    NSInteger bestPixels = -1;
    for (TFSTwitterEntityMediaVideoVariant* variant in media.videoInfo.variants) {
        if (![variant.contentType isEqualToString:@"video/mp4"])
            continue;
        NSURL* url = variant.url.length ? [NSURL URLWithString:variant.url] : nil;
        if (!url)
            continue;
        NSArray<NSString*>* dims =
            [[BHTManager getVideoQuality:url.absoluteString] componentsSeparatedByString:@"x"];
        NSInteger pixels =
            dims.count == 2 ? dims[0].integerValue * dims[1].integerValue : 0;
        if (pixels > bestPixels) {
            bestPixels = pixels;
            bestURL = url;
        }
    }
    return bestURL;
}

// Downloads every video in the tweet at its highest mp4 quality with one tap.
// Files download sequentially (each retried once on failure); at the end they
// are saved to Photos or handed to a single share sheet together, honouring
// the direct_save setting like single downloads do.
- (void)downloadAllVideosAtHighestQuality:(NSArray<TFSTwitterEntityMedia*>*)videoEntities {
    NSMutableArray<NSURL*>* bestURLs = [NSMutableArray new];
    for (TFSTwitterEntityMedia* media in videoEntities) {
        NSURL* url = BestMP4URLForMedia(media);
        if (url)
            [bestURLs addObject:url];
    }
    if (bestURLs.count == 0) {
        // HLS-only videos have no mp4 variant to stream-copy; say so instead
        // of silently doing nothing.
        NSString* noMP4 =
            [[BHTBundle sharedBundle] localizedStringForKey:@"DOWNLOAD_ALL_NO_MP4"];
        if ([noMP4 isEqualToString:@"DOWNLOAD_ALL_NO_MP4"])
            noMP4 = @"None of these videos offer a downloadable MP4.";
        [self presentFailureAlertWithMessage:noMP4
                                      command:@"bulk download"
                                    failTrace:@""];
        return;
    }

    NSString* progressFormat =
        [[BHTBundle sharedBundle] localizedStringForKey:@"DOWNLOAD_ALL_PROGRESS"];
    if ([progressFormat isEqualToString:@"DOWNLOAD_ALL_PROGRESS"])
        progressFormat = @"Downloading %lu of %lu";

    NSMutableArray<NSURL*>* outFiles = [NSMutableArray new];
    NSMutableArray<NSString*>* failureNotes = [NSMutableArray new];
    __block NSUInteger index = 0;
    __block NSInteger attempt = 0;
    __block void (^downloadNext)(void);
    downloadNext = ^{
        // FFmpegKit callbacks arrive off the main thread; keep all UI work
        // on main by re-dispatching every step.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (index >= bestURLs.count) {
                downloadNext = nil;  // break the self-retain cycle
                [self.hud hide];
                UINotificationFeedbackGenerator* feedback =
                    [UINotificationFeedbackGenerator new];
                [feedback prepare];
                if (failureNotes.count > 0) {
                    [feedback notificationOccurred:UINotificationFeedbackTypeError];
                    NSString* failedFormat = [[BHTBundle sharedBundle]
                        localizedStringForKey:@"DOWNLOAD_ALL_FAILED_MESSAGE"];
                    if ([failedFormat isEqualToString:@"DOWNLOAD_ALL_FAILED_MESSAGE"]) {
                        failedFormat = @"%lu of %lu downloads failed.";
                    }
                    [self presentFailureAlertWithMessage:
                              [NSString stringWithFormat:failedFormat,
                                                         (unsigned long)failureNotes.count,
                                                         (unsigned long)bestURLs.count]
                                                command:@"bulk download"
                                              failTrace:[failureNotes
                                                            componentsJoinedByString:@"\n\n"]];
                } else if ([BHTSettings boolForKey:@"direct_save"]) {
                    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
                    for (NSURL* file in outFiles)
                        [BHTManager save:file];
                } else {
                    [BHTManager showSaveVCForURLs:outFiles];
                }
                return;
            }

            if (attempt == 0) {
                self.hud = [[objc_getClass("TFNHUD") alloc]
                    initWithText:[NSString stringWithFormat:progressFormat,
                                                            (unsigned long)(index + 1),
                                                            (unsigned long)bestURLs.count]];
                [self.hud show];
            }
            NSURL* url = bestURLs[index];
            NSURL* outFile = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@.mp4", NSUUID.UUID.UUIDString]];
            NSString* command =
                [NSString stringWithFormat:@"-i \"%@\" -c copy -y \"%@\"",
                                             url.absoluteString, outFile.path];
            [FFmpegKit executeAsync:command
                withCompleteCallback:^(FFmpegSession* session) {
                    if ([ReturnCode isSuccess:[session getReturnCode]]) {
                        [outFiles addObject:outFile];
                        index++;
                        attempt = 0;
                    } else if (attempt < 1) {
                        attempt++;
                        NSLog(@"[NFB] Bulk download %lu/%lu failed, retrying",
                              (unsigned long)(index + 1),
                              (unsigned long)bestURLs.count);
                    } else {
                        NSString* trace =
                            [session getFailStackTrace] ?: [session getOutput] ?: @"";
                        [failureNotes
                            addObject:[NSString
                                          stringWithFormat:@"Video %lu (rc=%d):\n%@",
                                                           (unsigned long)(index + 1),
                                                           [[session getReturnCode] getValue],
                                                           trace]];
                        index++;
                        attempt = 0;
                    }
                    downloadNext();
                }
                withLogCallback:nil
                withStatisticsCallback:nil];
        });
    };
    downloadNext();
}

@end
