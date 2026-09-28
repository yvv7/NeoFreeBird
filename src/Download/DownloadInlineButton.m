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

// Minimal declarations for the X model objects we duck-type in
// FileBaseNameForStatus. The real classes aren't in our headers, and
// messaging id with a wholly undeclared selector is a hard error, so the
// compiler needs these signatures. Runtime behaviour is unchanged: every
// call is still guarded by respondsToSelector:. (Declarations only, no
// @implementation — these types are never instantiated.)
@interface NFBStatusDuckType : NSObject
- (id)author;
- (id)user;
- (NSDate*)createdAt;
@end
@interface NFBUserDuckType : NSObject
- (NSString*)screenName;
@end

// Fetches a URL as text with a hard timeout. Must be called off the main
// thread; returns nil when the fetch fails or times out.
static NSString* _Nullable HLSFetchText(NSURL* url, NSTimeInterval timeout) {
    if (!url)
        return nil;
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = timeout;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    __block NSString* result = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url
            completionHandler:^(NSData* data, NSURLResponse* response,
                                NSError* error) {
                if (data.length > 0)
                    result = [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding];
                dispatch_semaphore_signal(sema);
            }] resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [session invalidateAndCancel];
    return result;
}

// Parses an HLS master playlist into its variant streams, best-first by
// resolution (then bandwidth). Each entry: @{@"url": NSURL,
// @"width": NSNumber, @"height": NSNumber}. A playlist with no
// #EXT-X-STREAM-INF lines (already a media playlist) yields a single entry
// with width/height 0. Returns nil when the playlist can't be fetched.
static NSArray<NSDictionary*>* _Nullable HLSVariantStreams(NSURL* masterURL) {
    NSString* text = HLSFetchText(masterURL, 15);
    if (!text.length)
        return nil;
    NSArray<NSString*>* lines = [text
        componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSRegularExpression* resRE = [NSRegularExpression
        regularExpressionWithPattern:@"RESOLUTION=(\\d+)x(\\d+)"
                             options:0
                               error:nil];
    NSRegularExpression* bwRE = [NSRegularExpression
        regularExpressionWithPattern:@"BANDWIDTH=(\\d+)" options:0 error:nil];
    NSMutableArray<NSDictionary*>* variants = [NSMutableArray new];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString* line = [lines[i]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"])
            continue;
        NSInteger width = 0, height = 0;
        long long bandwidth = 0;
        NSTextCheckingResult* m = [resRE firstMatchInString:line
                                                   options:0
                                                     range:NSMakeRange(0, line.length)];
        if (m) {
            width = [[line substringWithRange:[m rangeAtIndex:1]] integerValue];
            height = [[line substringWithRange:[m rangeAtIndex:2]] integerValue];
        }
        m = [bwRE firstMatchInString:line
                             options:0
                               range:NSMakeRange(0, line.length)];
        if (m)
            bandwidth =
                [[line substringWithRange:[m rangeAtIndex:1]] longLongValue];
        // The variant URI is the next non-empty, non-comment line,
        // resolved against the master playlist like ffmpeg itself does.
        NSURL* variantURL = nil;
        for (NSUInteger j = i + 1; j < lines.count; j++) {
            NSString* uri = [lines[j]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!uri.length || [uri hasPrefix:@"#"])
                continue;
            variantURL = [NSURL URLWithString:uri relativeToURL:masterURL]
                             .absoluteURL ?: [NSURL URLWithString:uri];
            break;
        }
        if (!variantURL)
            continue;
        [variants addObject:@{
            @"url": variantURL,
            @"width": @(width),
            @"height": @(height),
            @"bandwidth": @(bandwidth)
        }];
    }
    if (variants.count == 0) {
        // Not a master playlist; the URL itself is the media playlist.
        return @[
            @{@"url": masterURL, @"width": @0, @"height": @0, @"bandwidth": @0}
        ];
    }
    [variants
        sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            long long pa =
                [a[@"width"] longLongValue] * [a[@"height"] longLongValue];
            long long pb =
                [b[@"width"] longLongValue] * [b[@"height"] longLongValue];
            if (pa != pb)
                return pa > pb ? NSOrderedAscending : NSOrderedDescending;
            long long ba = [a[@"bandwidth"] longLongValue];
            long long bb = [b[@"bandwidth"] longLongValue];
            if (ba == bb)
                return NSOrderedSame;
            return ba > bb ? NSOrderedAscending : NSOrderedDescending;
        }];
    return variants;
}

// Sums the #EXTINF durations of an HLS media playlist, in milliseconds.
// Used only for download progress display; 0 when unavailable.
static double HLSDurationMs(NSURL* mediaPlaylistURL) {
    NSString* text = HLSFetchText(mediaPlaylistURL, 15);
    double total = 0;
    for (NSString* rawLine in
             [text componentsSeparatedByCharactersInSet:
                        NSCharacterSet.newlineCharacterSet]) {
        NSString* line = [rawLine
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line hasPrefix:@"#EXTINF:"]) {
            NSString* secs =
                [[line substringFromIndex:@"#EXTINF:".length]
                    componentsSeparatedByString:@","][0];
            total += secs.doubleValue;
        }
    }
    return total * 1000.0;
}

// Builds a "screenName_yyyyMMdd_HHmmss" base name from a tweet status, or nil
// when the status doesn't expose the pieces. Backs smart filenames.
static id _Nullable NFBFindUserObject(id status, NSString* _Nullable * _Nullable viaOut) {
    // Fast paths: the known X API shapes.
    if ([status respondsToSelector:@selector(author)]) {
        id u = [(NFBStatusDuckType*)status author];
        if ([u respondsToSelector:@selector(screenName)]) {
            if (viaOut) *viaOut = @"author";
            return u;
        }
    }
    if ([status respondsToSelector:@selector(user)]) {
        id u = [(NFBStatusDuckType*)status user];
        if ([u respondsToSelector:@selector(screenName)]) {
            if (viaOut) *viaOut = @"user";
            return u;
        }
    }
    // Fallback: scan the status's properties for one vending an object that
    // answers screenName. Survives X renaming the user property.
    @try {
        unsigned int count = 0;
        objc_property_t* props = class_copyPropertyList(object_getClass(status), &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString* key =
                [NSString stringWithUTF8String:property_getName(props[i])];
            if ([key hasPrefix:@"_"] || [key hasPrefix:@"hash"]) {
                continue;
            }
            id value = nil;
            @try {
                value = [status valueForKey:key];
            } @catch (NSException* __unused ex) {
                continue;
            }
            if (value && value != status &&
                [value respondsToSelector:@selector(screenName)]) {
                if (viaOut) *viaOut = key;
                free(props);
                return value;
            }
        }
        free(props);
    } @catch (NSException* __unused ex) {
    }
    return nil;
}

static NSString* _Nullable FileBaseNameForStatus(id status) {
    NSString* screenName = nil;
    NSDate* createdAt = nil;
    NSString* via = @"none";
    @try {
        id userObj = NFBFindUserObject(status, &via);
        if (userObj) {
            screenName = [(NFBUserDuckType*)userObj screenName];
        }
        if ([status respondsToSelector:@selector(createdAt)])
            createdAt = [(NFBStatusDuckType*)status createdAt];
    } @catch (NSException* __unused ex) {
    }
    NSLog(@"[NFB] smart filename: status=%@ via=%@ screenName=%@ createdAt=%@",
          status ? NSStringFromClass([status class]) : @"nil", via, screenName,
          createdAt);
    if (![screenName isKindOfClass:NSString.class] || screenName.length == 0)
        return nil;
    NSCharacterSet* allowed = NSCharacterSet.alphanumericCharacterSet;
    NSMutableString* clean = [NSMutableString new];
    for (NSUInteger i = 0; i < screenName.length; i++) {
        unichar c = [screenName characterAtIndex:i];
        if ([allowed characterIsMember:c] || c == '_')
            [clean appendFormat:@"%C", c];
    }
    if (clean.length == 0)
        return nil;
    NSString* datePart = @"";
    if ([createdAt isKindOfClass:NSDate.class]) {
        NSDateFormatter* formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyyMMdd_HHmmss";
        datePart = [formatter stringFromDate:createdAt];
    }
    return datePart.length > 0 ? [NSString stringWithFormat:@"%@_%@", clean, datePart]
                               : [clean copy];
}

#pragma mark - DownloadInlineButton
@interface DownloadInlineButton ()
@property (nonatomic, strong) TFNHUD* hud;
@property (nonatomic, strong) FFmpegSession* currentSession;
@property (nonatomic, strong) UIButton* cancelButton;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingJobs;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* completedJobs;
@property (nonatomic, strong) NSMutableArray<NSString*>* failureNotes;
@property (nonatomic, assign) BOOL queueRunning;
@property (nonatomic, assign) BOOL cancelRequested;
@property (nonatomic, copy) NSString* fileNameBase;
@property (nonatomic, assign) NSUInteger fileNameCounter;
@end

@implementation DownloadInlineButton

#pragma mark - Download handler
- (void)presentDownloadOptionsForMediaEntities:(NSArray*)mediaEntities
                                         status:(id)status {
    @try {
        self.fileNameCounter = 0;
        self.fileNameBase =
            [BHTSettings boolForKey:@"download_smart_filenames"]
                ? FileBaseNameForStatus(status)
                : nil;
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

        // Every menu item funnels through here. With the background queue
        // enabled the job runs in the shared sequential queue; otherwise it
        // starts immediately, preserving the old behaviour.
        void (^ffmpegDownload)(NSString*, NSString*, double) = ^(
            NSString* args, NSString* ext, double durationMs) {
            NSDictionary* job = @{
                @"args": args,
                @"ext": ext,
                @"durationMs": @(durationMs),
                @"name": [self nextFileBaseName]
            };
            if ([BHTSettings boolForKey:@"download_queue"]) {
                [self enqueueDownloadJobs:@[ job ]];
            } else {
                [self runSingleDownloadJob:job];
            }
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

        // Audio-only: drop the video stream and copy the audio track as-is.
        TFNActionItem* (^makeAudioItem)(NSURL*, double) = ^TFNActionItem*(
            NSURL* url, double durationMs) {
            NSString* audioTitle = [[BHTBundle sharedBundle]
                localizedStringForKey:@"DOWNLOAD_AUDIO_MENU_TITLE"];
            if ([audioTitle isEqualToString:@"DOWNLOAD_AUDIO_MENU_TITLE"])
                audioTitle = @"Download audio";
            return [objc_getClass("TFNActionItem")
                actionItemWithTitle:audioTitle
                          imageName:@"arrow_down_circle_stroke"
                             action:^{
                                 ffmpegDownload(
                                     [NSString stringWithFormat:@"-i \"%@\" -vn -c:a copy",
                                                                url.absoluteString],
                                     @"m4a", durationMs);
                             }];
        };

        // HLS renditions are downloaded with a plain stream copy of their
        // own variant playlist: no re-encode, so no VideoToolbox failures,
        // no quality loss, and the exact rendition the user tapped.
        TFNActionItem* (^makeHLSItem)(NSURL*, NSString*, double) = ^TFNActionItem*(
            NSURL* url, NSString* resolution, double durationMs) {
            return [objc_getClass("TFNActionItem")
                actionItemWithTitle:resolution
                          imageName:@"arrow_down_circle_stroke"
                             action:^{
                                 ffmpegDownload(
                                     [NSString stringWithFormat:@"-i \"%@\" -c copy",
                                                                url.absoluteString],
                                     @"mp4", durationMs);
                             }];
        };

        // videoInfo.variants backs both video (mediaType 3) and GIF (mediaType 2);
        // photos carry no videoInfo. The master playlist is fetched and parsed
        // directly (with a timeout) so every rendition is offered in a single
        // sheet. mp4 variants win when both carry the same resolution; media
        // without a playlist (GIFs) skips the fetch entirely.
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
                if ([BHTSettings boolForKey:@"download_audio_option"] &&
                    media.mediaType == 3 && mp4URLs.count > 0) {
                    [items addObject:makeAudioItem(mp4URLs.firstObject, 0)];
                }
                done(items);
                return;
            }

            showHUD([[BHTBundle sharedBundle]
                localizedStringForKey:@"FETCHING_PROGRESS_TITLE"]);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // Parse the master playlist ourselves instead of probing with
                // FFprobeKit: each rendition gets its own variant playlist URL
                // for a direct stream copy, and the fetch has a hard timeout
                // so a dead playlist can't hang the sheet on "Just a second..."
                // forever.
                NSArray<NSDictionary*>* hlsVariants = HLSVariantStreams(m3u8URL);
                double durationMs = 0;
                if (hlsVariants.count > 0)
                    durationMs = HLSDurationMs(hlsVariants[0][@"url"]);

                dispatch_async(dispatch_get_main_queue(), ^{
                    dismissHUD();
                    appendMP4Items(durationMs);
                    BOOL addedHLS = NO;
                    for (NSDictionary* variant in hlsVariants) {
                        NSInteger width = [variant[@"width"] integerValue];
                        NSInteger height = [variant[@"height"] integerValue];
                        if (width <= 0 || height <= 0)
                            continue;
                        NSString* resolution = [NSString
                            stringWithFormat:@"%ldx%ld", (long)width, (long)height];
                        if ([offered containsObject:resolution])
                            continue;

                        [offered addObject:resolution];
                        addedHLS = YES;
                        [items addObject:makeHLSItem(variant[@"url"], resolution,
                                                    durationMs)];
                    }
                    if (!addedHLS && hlsVariants.count > 0) {
                        // Media playlist with no labeled renditions: still
                        // offer it rather than leaving HLS-only videos with an
                        // empty sheet.
                        [items addObject:makeHLSItem(hlsVariants[0][@"url"],
                                                    [[BHTBundle sharedBundle]
                                                        localizedStringForKey:
                                                            @"DOWNLOAD_AS_MP4_OPTION_TITLE"],
                                                    durationMs)];
                    }
                    if ([BHTSettings boolForKey:@"download_audio_option"] &&
                        media.mediaType == 3) {
                        NSURL* audioURL = mp4URLs.firstObject ?:
                                          (hlsVariants.count > 0 ? hlsVariants[0][@"url"] : nil);
                        if (audioURL)
                            [items addObject:makeAudioItem(audioURL, durationMs)];
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

// Best downloadable URL for a media entity: the highest-quality mp4
// variant, else the best HLS variant playlist (stream-copied, no
// re-encode). Does network I/O for HLS playlists: call off the main thread.
static NSURL* _Nullable BestDownloadURLForMedia(TFSTwitterEntityMedia* media) {
    NSURL* mp4URL = BestMP4URLForMedia(media);
    if (mp4URL)
        return mp4URL;
    NSURL* m3u8URL = nil;
    for (TFSTwitterEntityMediaVideoVariant* variant in media.videoInfo.variants) {
        if ([variant.contentType isEqualToString:@"application/x-mpegURL"] &&
            variant.url.length) {
            m3u8URL = [NSURL URLWithString:variant.url];
            break;
        }
    }
    if (!m3u8URL)
        return nil;
    NSArray<NSDictionary*>* variants = HLSVariantStreams(m3u8URL);
    return variants.count > 0 ? variants[0][@"url"] : nil;
}

// Downloads every video in the tweet at its highest quality with one tap.
// Jobs run through the shared sequential engine: each retried once on
// failure, progress as "i of n", and one combined delivery at the end.
- (void)downloadAllVideosAtHighestQuality:(NSArray<TFSTwitterEntityMedia*>*)videoEntities {
    // Resolving the best URL per video can hit the network (HLS master
    // playlists), so do it off the main thread. File names are minted on
    // the main thread first to keep the counter race-free.
    NSMutableArray<NSString*>* names = [NSMutableArray new];
    for (__unused TFSTwitterEntityMedia* media in videoEntities)
        [names addObject:[self nextFileBaseName]];
    self.hud = [[objc_getClass("TFNHUD") alloc]
        initWithText:[[BHTBundle sharedBundle]
                         localizedStringForKey:@"FETCHING_PROGRESS_TITLE"]];
    [self.hud show];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary*>* jobs = [NSMutableArray new];
        for (NSUInteger idx = 0; idx < videoEntities.count; idx++) {
            NSURL* url = BestDownloadURLForMedia(videoEntities[idx]);
            if (!url)
                continue;
            [jobs addObject:@{
                @"args":
                    [NSString stringWithFormat:@"-i \"%@\" -c copy",
                                               url.absoluteString],
                @"ext": @"mp4",
                @"durationMs": @0,
                @"name": names[idx]
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.hud hide];
            if (jobs.count == 0) {
                NSString* noVideo = [[BHTBundle sharedBundle]
                    localizedStringForKey:@"DOWNLOAD_ALL_NO_MP4"];
                if ([noVideo isEqualToString:@"DOWNLOAD_ALL_NO_MP4"])
                    noVideo = @"None of these videos could be downloaded.";
                [self presentFailureAlertWithMessage:noVideo
                                              command:@"bulk download"
                                            failTrace:@""];
                return;
            }
            [self enqueueDownloadJobs:jobs];
        });
    });
}

// Direct download of one video URL, no media entities and no quality sheet.
// Used by the immersive player's in-video download button: there we know
// the exact rendition X is playing, but the player's "..." menu is built
// outside _t1_actionItemsForStatus: so our "Download media" entry never
// appears in it. Honors the sequential queue, tap-to-cancel, and
// save-to-Files settings like every other download path. No status is
// available here, so the file gets a UUID name (same as DMs).
- (void)downloadVideoAtURL:(NSURL*)url {
    if (![url isKindOfClass:NSURL.class] || url.absoluteString.length == 0) {
        return;
    }
    // The job engine drives HUD UI: it must run on the main thread.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadVideoAtURL:url];
        });
        return;
    }
    self.fileNameCounter = 0;
    self.fileNameBase = nil;
    NSDictionary* job = @{
        @"args": [NSString
            stringWithFormat:@"-i \"%@\" -c copy", url.absoluteString],
        @"ext": @"mp4",
        @"durationMs": @0,
        @"name": [self nextFileBaseName]
    };
    if ([BHTSettings boolForKey:@"download_queue"]) {
        [self enqueueDownloadJobs:@[ job ]];
    } else {
        [self runSingleDownloadJob:job];
    }
}

#pragma mark - Download job engine

// Next output base name: smart "user_date" (with _2, _3… suffixes) when
// enabled and available, otherwise a random UUID like before.
- (NSString*)nextFileBaseName {
    if (!self.fileNameBase.length)
        return NSUUID.UUID.UUIDString;
    self.fileNameCounter++;
    return self.fileNameCounter > 1
               ? [NSString stringWithFormat:@"%@_%lu", self.fileNameBase,
                                                (unsigned long)self.fileNameCounter]
               : self.fileNameBase;
}

// One ffmpeg invocation with a single automatic retry. Completion runs on
// the main queue: outFile is set on success; on failure, failure carries
// @{@"rc", @"trace", @"command"}; both nil means the user cancelled.
- (void)runFFmpegJob:(NSDictionary*)job
        progressText:(NSString*)progressText
          completion:(void (^)(NSURL* _Nullable, NSDictionary* _Nullable))completion {
    NSString* args = job[@"args"];
    NSString* ext = job[@"ext"];
    double durationMs = [job[@"durationMs"] doubleValue];
    NSString* name = job[@"name"];
    NSURL* outFile = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", name, ext]];
    // Quote the output path and retry once on failure: X's media URLs
    // are signed and can briefly 403/timeout, so a single ffmpeg
    // attempt makes downloads flaky. -y lets the retry overwrite the
    // partial file left behind by the first attempt. -rw_timeout keeps
    // a stalled connection from hanging forever (which used to leave
    // the "Downloading" HUD up indefinitely); the stall becomes a
    // normal failure and flows into the retry/error path instead.
    NSString* command = [NSString
        stringWithFormat:@"-rw_timeout 15000000 %@ -y \"%@\"", args, outFile.path];

    // Always called on the main thread (menu actions and queue steps).
    self.cancelRequested = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hud = [[objc_getClass("TFNHUD") alloc] initWithText:progressText];
        [self.hud show];
        [self showCancelButton];
    });

    __block void (^runAttempt)(void);
    __block NSInteger attempt = 0;
    runAttempt = ^{
        attempt++;
        FFmpegSession* session =
            [FFmpegKit executeAsync:command
                withCompleteCallback:^(FFmpegSession* s) {
                    ReturnCode* returnCode = [s getReturnCode];
                    BOOL cancelled = self.cancelRequested ||
                                     [ReturnCode isCancel:returnCode];
                    if (![ReturnCode isSuccess:returnCode] && !cancelled &&
                        attempt < 2) {
                        NSLog(@"[NFB] Download attempt %ld failed (rc=%@), "
                              @"retrying: %@",
                              (long)attempt,
                              returnCode
                                  ? [NSString stringWithFormat:@"%d",
                                                               [returnCode getValue]]
                                  : @"n/a",
                              [s getCommand]);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.hud setText:progressText];
                        });
                        runAttempt();
                        return;
                    }
                    runAttempt = nil;  // break the self-retain cycle
                    self.currentSession = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.hud hide];
                        [self hideCancelButton];
                        if (cancelled) {
                            completion(nil, nil);
                        } else if ([ReturnCode isSuccess:returnCode]) {
                            completion(outFile, nil);
                        } else {
                            NSString* rcString =
                                returnCode
                                    ? [NSString stringWithFormat:@"%d",
                                                                 [returnCode getValue]]
                                    : @"n/a";
                            NSString* failTrace =
                                [s getFailStackTrace] ?: @"";
                            if (failTrace.length == 0)
                                failTrace = [s getOutput] ?: @"";
                            completion(nil, @{
                                @"rc": rcString,
                                @"trace": failTrace,
                                @"command": [s getCommand] ?: @""
                            });
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
                    [self.hud setText:[NSString stringWithFormat:@"%@ %@", progressText,
                                                                   detail]];
                });
            }];
        self.currentSession = session;
    };
    runAttempt();
}

// Immediate single download (background queue disabled): one job, delivered
// or alerted right away, like the old behaviour.
- (void)runSingleDownloadJob:(NSDictionary*)job {
    NSString* downloadingText = [[BHTBundle sharedBundle]
        localizedStringForKey:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"];
    if ([downloadingText isEqualToString:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"])
        downloadingText = @"Downloading";
    [self runFFmpegJob:job
          progressText:downloadingText
            completion:^(NSURL* outFile, NSDictionary* failure) {
                UINotificationFeedbackGenerator* feedback =
                    [UINotificationFeedbackGenerator new];
                [feedback prepare];
                if (outFile) {
                    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
                    [self deliverFile:outFile ext:job[@"ext"]];
                } else if (failure) {
                    [feedback notificationOccurred:UINotificationFeedbackTypeError];
                    NSString* failedFormat = [[BHTBundle sharedBundle]
                        localizedStringForKey:@"DOWNLOAD_FAILED_MESSAGE"];
                    if ([failedFormat isEqualToString:@"DOWNLOAD_FAILED_MESSAGE"])
                        failedFormat = @"Download failed (code %@).";
                    [self presentFailureAlertWithMessage:
                              [NSString stringWithFormat:failedFormat, failure[@"rc"]]
                                                  command:failure[@"command"]
                                                failTrace:failure[@"trace"]];
                }
                // Cancelled: stay quiet.
            }];
}

// Queue entry point. Jobs run sequentially; the user can keep browsing while
// they finish. Tapping an item again just adds to the queue.
- (void)enqueueDownloadJobs:(NSArray<NSDictionary*>*)jobs {
    if (jobs.count == 0)
        return;
    if (!self.pendingJobs)
        self.pendingJobs = [NSMutableArray new];
    [self.pendingJobs addObjectsFromArray:jobs];
    [self processDownloadQueue];
}

- (void)processDownloadQueue {
    if (self.queueRunning)
        return;
    self.queueRunning = YES;
    self.completedJobs = [NSMutableArray new];
    self.failureNotes = [NSMutableArray new];
    [self runNextQueuedJob];
}

- (void)runNextQueuedJob {
    if (self.cancelRequested || self.pendingJobs.count == 0) {
        [self finishDownloadQueue];
        return;
    }
    NSDictionary* job = self.pendingJobs.firstObject;
    [self.pendingJobs removeObjectAtIndex:0];
    NSUInteger doneCount = self.completedJobs.count + self.failureNotes.count;
    NSUInteger totalCount = doneCount + self.pendingJobs.count + 1;
    NSString* format = [[BHTBundle sharedBundle]
        localizedStringForKey:@"DOWNLOAD_QUEUE_PROGRESS"];
    if ([format isEqualToString:@"DOWNLOAD_QUEUE_PROGRESS"])
        format = @"Downloading %lu of %lu";
    NSString* progressText =
        [NSString stringWithFormat:format, (unsigned long)(doneCount + 1),
                                    (unsigned long)totalCount];
    NSString* jobName = job[@"name"];
    [self runFFmpegJob:job
          progressText:progressText
            completion:^(NSURL* outFile, NSDictionary* failure) {
                if (outFile) {
                    [self.completedJobs
                        addObject:@{@"url": outFile, @"ext": job[@"ext"] ?: @"mp4"}];
                } else if (failure) {
                    // Keep the alert readable: tail of the trace, where the
                    // actual error lives. The full trace is one tap away via
                    // Copy details.
                    NSString* trace = failure[@"trace"] ?: @"";
                    if (trace.length > 800)
                        trace = [@"…\n"
                            stringByAppendingString:
                                [trace substringFromIndex:trace.length - 800]];
                    [self.failureNotes
                        addObject:[NSString stringWithFormat:@"%@ (rc=%@):\n%@",
                                                             jobName, failure[@"rc"],
                                                             trace]];
                }
                [self runNextQueuedJob];
            }];
}

- (void)finishDownloadQueue {
    self.queueRunning = NO;
    self.cancelRequested = NO;
    UINotificationFeedbackGenerator* feedback =
        [UINotificationFeedbackGenerator new];
    [feedback prepare];
    // Deliver the successes first; the failure summary follows after a beat
    // so it lands on top of (not inside) any sheet/picker animation.
    [self deliverFiles:self.completedJobs];
    if (self.failureNotes.count > 0) {
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        NSString* failedFormat = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DOWNLOAD_QUEUE_FAILED_MESSAGE"];
        if ([failedFormat isEqualToString:@"DOWNLOAD_QUEUE_FAILED_MESSAGE"])
            failedFormat = @"%lu of %lu queued downloads failed.";
        NSUInteger total = self.completedJobs.count + self.failureNotes.count;
        NSString* message =
            [NSString stringWithFormat:failedFormat,
                                      (unsigned long)self.failureNotes.count,
                                      (unsigned long)total];
        NSString* trace =
            [self.failureNotes componentsJoinedByString:@"\n\n"];
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self presentFailureAlertWithMessage:message
                                              command:@"queued downloads"
                                            failTrace:trace];
            });
    } else if (self.completedJobs.count > 0) {
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    self.pendingJobs = nil;
    self.completedJobs = nil;
    self.failureNotes = nil;
}

#pragma mark - Delivery

// Routes finished files to the Files app, Photos, or the share sheet.
// download_to_files wins over direct_save.
- (void)deliverFile:(NSURL*)file ext:(NSString*)ext {
    [self deliverFiles:@[ @{@"url": file, @"ext": ext ?: @"mp4"} ]];
}

- (void)deliverFiles:(NSArray<NSDictionary*>*)items {
    NSMutableArray<NSURL*>* files = [NSMutableArray new];
    for (NSDictionary* item in items)
        [files addObject:item[@"url"]];
    if (files.count == 0)
        return;
    if ([BHTSettings boolForKey:@"download_to_files"]) {
        [self exportFilesToFilesApp:files];
        return;
    }
    // PhotoKit's video save path can't take audio-only files; those always
    // go through the share sheet.
    BOOL hasAudioOnly = NO;
    for (NSDictionary* item in items) {
        if ([item[@"ext"] isEqualToString:@"m4a"]) {
            hasAudioOnly = YES;
            break;
        }
    }
    if ([BHTSettings boolForKey:@"direct_save"] && !hasAudioOnly) {
        for (NSDictionary* item in items) {
            if ([item[@"ext"] isEqualToString:@"gif"])
                [BHTManager saveGIF:item[@"url"]];
            else
                [BHTManager save:item[@"url"]];
        }
        return;
    }
    [BHTManager showSaveVCForURLs:files];
}

- (void)exportFilesToFilesApp:(NSArray<NSURL*>*)files {
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:files
                                                             asCopy:YES];
    [TopMostController() presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Cancel

// TFNHUD is a plain NSObject with no touch handling, so the cancel control
// is our own floating pill. Tapping it cancels the in-flight ffmpeg session;
// the job is then treated as cancelled (no retry, no error alert).
- (void)showCancelButton {
    if (self.cancelButton ||
        ![BHTSettings boolForKey:@"download_tap_to_cancel"])
        return;
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString* title = [[BHTBundle sharedBundle]
        localizedStringForKey:@"DOWNLOAD_CANCEL_BUTTON_TITLE"];
    if ([title isEqualToString:@"DOWNLOAD_CANCEL_BUTTON_TITLE"])
        title = @"Cancel";
    [button setTitle:[@"✕ " stringByAppendingString:title]
            forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15
                                               weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 20;
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 18, 10, 18);
    [button addTarget:self
               action:@selector(cancelCurrentDownload)
     forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIWindow* window = KeyWindow();
    if (!window)
        return;
    [window addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [button.bottomAnchor
            constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                           constant:-24]
    ]];
    self.cancelButton = button;
}

- (void)hideCancelButton {
    [self.cancelButton removeFromSuperview];
    self.cancelButton = nil;
}

- (void)cancelCurrentDownload {
    self.cancelRequested = YES;
    [self hideCancelButton];
    [self.currentSession cancel];
}

@end
