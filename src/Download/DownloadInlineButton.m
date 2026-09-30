//
#import "Diagnostics/NFBDiagnostics.h"
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
#import "Core/NFBToast.h"
#import "Core/NFBProgressPill.h"

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
- (NSString*)fromUserName;
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
        // Fast path: TFNTwitterStatus has fromUserName as a direct string.
        // Check this BEFORE looking for a user object.
        if ([status respondsToSelector:@selector(fromUserName)]) {
            id name = [(NFBStatusDuckType*)status fromUserName];
            if ([name isKindOfClass:NSString.class] && [(NSString*)name length] > 0) {
                screenName = (NSString*)name;
                via = @"fromUserName";
            }
        }
        // Fallback: find a user object with screenName.
        if (!screenName) {
            id userObj = NFBFindUserObject(status, &via);
            if (userObj) {
                screenName = [(NFBUserDuckType*)userObj screenName];
            }
        }
        if ([status respondsToSelector:@selector(createdAt)])
            createdAt = [(NFBStatusDuckType*)status createdAt];
    } @catch (NSException* __unused ex) {
    }
    NFBLog(@"smart filename: status=%@ via=%@ screenName=%@ createdAt=%@",
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
    // Use the tweet's date if available, otherwise the current time.
    // A filename without a date risks collisions, so always include one.
    NSDate* dateToUse = [createdAt isKindOfClass:NSDate.class] ? createdAt : [NSDate date];
    {
        NSDateFormatter* formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyyMMdd_HHmmss";
        datePart = [formatter stringFromDate:dateToUse];
    }
    return datePart.length > 0 ? [NSString stringWithFormat:@"%@_%@", clean, datePart]
                               : [clean copy];
}

#pragma mark - DownloadInlineButton
@interface DownloadInlineButton ()
@property (nonatomic, strong) TFNHUD* hud;
@property (nonatomic, copy) NSString* fileNameBase;
@property (nonatomic, assign) NSUInteger fileNameCounter;
// Stashed base for async HLS resolution in downloadVideoAtURL:fileNameBase:.
@property (nonatomic, copy) NSString* pendingFileNameBase;
@end

// Shared sequential download queue engine across all button instances.
static NSMutableArray<NSDictionary*>* sPendingJobs = nil;
static NSMutableArray<NSDictionary*>* sCompletedJobs = nil;
static NSMutableArray<NSString*>* sFailureNotes = nil;
static BOOL sQueueRunning = NO;
static BOOL sCancelRequested = NO;
static FFmpegSession* sCurrentSession = nil;
static NFBProgressPill* sProgressPill = nil;
static UIButton* sCancelButton = nil;
static NSUInteger sTotalQueueCount = 0;

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

        void (^showHUD)(NSString*) = ^(NSString* __unused text) {
            // Middle progress HUD disabled — pill confirmation only.
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
    NFBLog(@"%@ command=%@\n%@", message, command, failTrace);

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
    // Middle progress HUD disabled — pill confirmation only.
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
    [self downloadVideoAtURL:url fileNameBase:nil];
}

- (void)downloadVideoAtURL:(NSURL*)url fileNameBase:(NSString* _Nullable)base {
    if (![url isKindOfClass:NSURL.class] || url.absoluteString.length == 0) {
        return;
    }
    // The job engine drives HUD UI: it must run on the main thread.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadVideoAtURL:url fileNameBase:base];
        });
        return;
    }
    // Stash the base; downloadResolvedVideoAtURL picks it up.
    self.pendingFileNameBase = base;
    // For HLS master playlists, resolve to the best variant URL first.
    // Master playlists reference subtitles that break ffmpeg; variants don't.
    if ([url.absoluteString.lowercaseString containsString:@".m3u8"]) {
        NFBLog(@"immersive download: resolving HLS variants for %@",
               url.absoluteString);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSDictionary*>* variants = HLSVariantStreams(url);
            NSURL* bestURL = url;
            if (variants.count > 0) {
                // Already sorted best-first by resolution.
                bestURL = variants[0][@"url"];
                NFBLog(@"immersive download: best variant %@",
                       bestURL.absoluteString);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self downloadResolvedVideoAtURL:bestURL];
            });
        });
        return;
    }
    [self downloadResolvedVideoAtURL:url];
}

- (void)downloadResolvedVideoAtURL:(NSURL*)url {
    self.fileNameCounter = 0;
    // Use the stashed base (from immersive) or nil for UUID.
    self.fileNameBase = self.pendingFileNameBase;
    self.pendingFileNameBase = nil;
    NSDictionary* job = @{
        @"args": [NSString stringWithFormat:@"-i \"%@\" -c copy",
                                           url.absoluteString],
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

// Save a UIImage to a temp file, then route through the normal delivery
// (Photos / share sheet / Files) with a smart filename.
- (void)downloadImage:(UIImage*)image fileNameBase:(NSString* _Nullable)base {
    if (!image) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // JPEG at high quality; fall back to PNG if JPEG fails.
        NSData* data = UIImageJPEGRepresentation(image, 0.92);
        NSString* ext = @"jpg";
        if (!data) {
            data = UIImagePNGRepresentation(image);
            ext = @"png";
        }
        if (!data) {
            NFBLog(@"immersive download: failed to encode image");
            return;
        }
        NSString* name = base.length ? base : NSUUID.UUID.UUIDString;
        NSString* tmpPath =
            [NSTemporaryDirectory() stringByAppendingPathComponent:
                                       [name stringByAppendingPathExtension:ext]];
        if (![data writeToFile:tmpPath atomically:YES]) {
            NFBLog(@"immersive download: failed to write image file");
            return;
        }
        NFBLog(@"immersive download: image saved to %@", tmpPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self deliverFile:[NSURL fileURLWithPath:tmpPath] ext:ext];
        });
    });
}

- (void)downloadImages:(NSArray<UIImage*>*)images
         fileNameBase:(NSString* _Nullable)base {
    if (images.count == 0) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString*>* paths = [NSMutableArray new];
        for (NSUInteger i = 0; i < images.count; i++) {
            UIImage* image = images[i];
            NSData* data = UIImageJPEGRepresentation(image, 0.92);
            NSString* ext = @"jpg";
            if (!data) {
                data = UIImagePNGRepresentation(image);
                ext = @"png";
            }
            if (!data) {
                continue;
            }
            NSString* name = base.length
                                 ? [NSString stringWithFormat:@"%@_%lu", base,
                                                            (unsigned long)(i + 1)]
                                 : NSUUID.UUID.UUIDString;
            NSString* tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:
                    [name stringByAppendingPathExtension:ext]];
            if ([data writeToFile:tmpPath atomically:YES]) {
                [paths addObject:tmpPath];
            }
        }
        NFBLog(@"immersive download: %lu images saved", (unsigned long)paths.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSDictionary*>* items = [NSMutableArray new];
            for (NSString* path in paths) {
                NSString* e = [path pathExtension] ?: @"jpg";
                [items addObject:@{
                    @"url": [NSURL fileURLWithPath:path],
                    @"ext": e
                }];
            }
            [self deliverFiles:items];
        });
    });
}

// Download images from URLs: fetch each, save to temp, deliver.
- (void)downloadImageURLs:(NSArray<NSURL*>*)urls
            fileNameBase:(NSString* _Nullable)base {
    if (urls.count == 0) {
        return;
    }
    NFBLog(@"download: fetching %lu image URLs", (unsigned long)urls.count);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString*>* paths = [NSMutableArray new];
        for (NSUInteger i = 0; i < urls.count; i++) {
            NSURL* url = urls[i];
            NSData* data = [NSData dataWithContentsOfURL:url];
            if (!data) {
                NFBLog(@"download: failed to fetch %@", url.absoluteString);
                continue;
            }
            // Detect extension from URL or data.
            NSString* ext = [url.pathExtension lowercaseString];
            if (![@[@"jpg", @"jpeg", @"png", @"gif", @"heic", @"webp"] containsObject:ext]) {
                ext = @"jpg";
            }
            NSString* name = base.length
                                 ? (urls.count > 1
                                        ? [NSString stringWithFormat:@"%@_%lu", base,
                                                               (unsigned long)(i + 1)]
                                        : base)
                                 : NSUUID.UUID.UUIDString;
            NSString* tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:
                    [name stringByAppendingPathExtension:ext]];
            if ([data writeToFile:tmpPath atomically:YES]) {
                [paths addObject:tmpPath];
            }
        }
        NFBLog(@"download: %lu images fetched", (unsigned long)paths.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSDictionary*>* items = [NSMutableArray new];
            for (NSString* path in paths) {
                [items addObject:@{
                    @"url": [NSURL fileURLWithPath:path],
                    @"ext": [path pathExtension] ?: @"jpg"
                }];
            }
            [self deliverFiles:items];
        });
    });
}

- (NSString* _Nullable)fileBaseForStatus:(id)status {
    return FileBaseNameForStatus(status);
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
    sCancelRequested = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Show or smoothly update progress pill at the top.
        NSString* title = progressText ?: @"Downloading";
        if (sProgressPill) {
            [sProgressPill updateTitle:title];
            [sProgressPill setProgress:0 detail:@"0%"];
        } else {
            sProgressPill = [NFBProgressPill showWithTitle:title];
        }
        // Keep the cancel button so users can abort.
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
                    BOOL cancelled = sCancelRequested ||
                                     [ReturnCode isCancel:returnCode];
                    if (![ReturnCode isSuccess:returnCode] && !cancelled &&
                        attempt < 2) {
                        NFBLog(@"Download attempt %ld failed (rc=%@), "
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
                    sCurrentSession = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.hud hide];
                        if (cancelled) {
                            [self hideCancelButton];
                            [sProgressPill dismiss];
                            sProgressPill = nil;
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
                CGFloat progress = 0;
                NSString* detail = nil;
                if (durationMs > 0) {
                    progress = MIN([statistics getTime] / durationMs, 1.0);
                    detail = [BHTManager getDownloadingPercent:progress];
                } else if ([statistics getSize] > 0) {
                    detail = [NSByteCountFormatter
                        stringFromByteCount:[statistics getSize]
                                 countStyle:NSByteCountFormatterCountStyleFile];
                    // No duration: fake progress based on size (cap at 90%).
                    progress = MIN([statistics getSize] / 10000000.0, 0.9);
                } else {
                    return;
                }
                NFBProgressPill* pill = sProgressPill;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [pill setProgress:progress detail:detail];
                });
            }];
        sCurrentSession = session;
    };
    runAttempt();
}

// Immediate single download (background queue disabled): one job, delivered
// or alerted right away, like the old behaviour.
- (void)runSingleDownloadJob:(NSDictionary*)job {
    // If the shared queue is already running, route through queue to prevent collision.
    if (sQueueRunning) {
        [self enqueueDownloadJobs:@[ job ]];
        return;
    }
    NSString* downloadingText = [[BHTBundle sharedBundle]
        localizedStringForKey:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"];
    if ([downloadingText isEqualToString:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"])
        downloadingText = @"Downloading";
    [self runFFmpegJob:job
          progressText:downloadingText
            completion:^(NSURL* outFile, NSDictionary* failure) {
                [self hideCancelButton];
                UINotificationFeedbackGenerator* feedback =
                    [UINotificationFeedbackGenerator new];
                [feedback prepare];
                if (outFile) {
                    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
                    if (sProgressPill) {
                        [sProgressPill dismiss];
                        sProgressPill = nil;
                    }
                    [self deliverFile:outFile ext:job[@"ext"]];
                } else if (failure) {
                    if (sProgressPill) {
                        [sProgressPill dismiss];
                        sProgressPill = nil;
                    }
                    [feedback notificationOccurred:UINotificationFeedbackTypeError];
                    NSString* failedFormat = [[BHTBundle sharedBundle]
                        localizedStringForKey:@"DOWNLOAD_FAILED_MESSAGE"];
                    if ([failedFormat isEqualToString:@"DOWNLOAD_FAILED_MESSAGE"])
                        failedFormat = @"Download failed (code %@).";
                    [self presentFailureAlertWithMessage:
                              [NSString stringWithFormat:failedFormat, failure[@"rc"]]
                                                  command:failure[@"command"]
                                                failTrace:failure[@"trace"]];
                } else {
                    if (sProgressPill) {
                        [sProgressPill dismiss];
                        sProgressPill = nil;
                    }
                }
            }];
}

// Queue entry point. Jobs run sequentially in a shared engine across all tweets;
// the user can keep browsing while they finish. Tapping an item again just adds to the queue.
- (void)enqueueDownloadJobs:(NSArray<NSDictionary*>*)jobs {
    if (jobs.count == 0)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sPendingJobs)
            sPendingJobs = [NSMutableArray new];
        [sPendingJobs addObjectsFromArray:jobs];
        if (!sQueueRunning) {
            sTotalQueueCount = sPendingJobs.count;
            [self processDownloadQueue];
        } else {
            // Already running! Increment total queue count and update pill title immediately.
            sTotalQueueCount += jobs.count;
            NSUInteger doneCount = (sCompletedJobs.count + sFailureNotes.count);
            NSUInteger currentNumber = doneCount + 1;
            NSString* format = [[BHTBundle sharedBundle]
                localizedStringForKey:@"DOWNLOAD_QUEUE_PROGRESS"];
            if ([format isEqualToString:@"DOWNLOAD_QUEUE_PROGRESS"])
                format = @"Downloading %lu of %lu";
            NSString* progressText = [NSString stringWithFormat:format,
                                      (unsigned long)currentNumber,
                                      (unsigned long)sTotalQueueCount];
            [sProgressPill updateTitle:progressText];
        }
    });
}

- (void)processDownloadQueue {
    if (sQueueRunning)
        return;
    sQueueRunning = YES;
    sCancelRequested = NO;
    sCompletedJobs = [NSMutableArray new];
    sFailureNotes = [NSMutableArray new];
    [self runNextQueuedJob];
}

- (void)runNextQueuedJob {
    if (sCancelRequested || sPendingJobs.count == 0) {
        [self finishDownloadQueue];
        return;
    }
    NSDictionary* job = sPendingJobs.firstObject;
    [sPendingJobs removeObjectAtIndex:0];
    NSUInteger doneCount = sCompletedJobs.count + sFailureNotes.count;
    NSUInteger totalCount = sTotalQueueCount;
    if (totalCount < doneCount + sPendingJobs.count + 1) {
        totalCount = doneCount + sPendingJobs.count + 1;
        sTotalQueueCount = totalCount;
    }
    NSString* progressText = nil;
    if (totalCount > 1) {
        NSString* format = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DOWNLOAD_QUEUE_PROGRESS"];
        if ([format isEqualToString:@"DOWNLOAD_QUEUE_PROGRESS"])
            format = @"Downloading %lu of %lu";
        progressText = [NSString stringWithFormat:format, (unsigned long)(doneCount + 1),
                                                 (unsigned long)totalCount];
    } else {
        NSString* downloadingText = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"];
        if ([downloadingText isEqualToString:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"])
            downloadingText = @"Downloading";
        progressText = downloadingText;
    }
    NSString* jobName = job[@"name"];
    [self runFFmpegJob:job
          progressText:progressText
            completion:^(NSURL* outFile, NSDictionary* failure) {
                if (outFile) {
                    [sCompletedJobs
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
                    [sFailureNotes
                        addObject:[NSString stringWithFormat:@"%@ (rc=%@):\n%@",
                                                             jobName, failure[@"rc"],
                                                             trace]];
                }
                [self runNextQueuedJob];
            }];
}

- (void)finishDownloadQueue {
    sQueueRunning = NO;
    sCancelRequested = NO;
    [self hideCancelButton];
    UINotificationFeedbackGenerator* feedback =
        [UINotificationFeedbackGenerator new];
    [feedback prepare];
    // Deliver the successes first; the failure summary follows after a beat
    // so it lands on top of (not inside) any sheet/picker animation.
    NSArray* finishedItems = [sCompletedJobs copy];
    NSArray* failures = [sFailureNotes copy];
    sPendingJobs = nil;
    sCompletedJobs = nil;
    sFailureNotes = nil;
    sTotalQueueCount = 0;

    if (sProgressPill) {
        [sProgressPill dismiss];
        sProgressPill = nil;
    }

    [self deliverFiles:finishedItems];
    if (failures.count > 0) {
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        NSString* failedFormat = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DOWNLOAD_QUEUE_FAILED_MESSAGE"];
        if ([failedFormat isEqualToString:@"DOWNLOAD_QUEUE_FAILED_MESSAGE"])
            failedFormat = @"%lu of %lu queued downloads failed.";
        NSUInteger total = finishedItems.count + failures.count;
        NSString* message =
            [NSString stringWithFormat:failedFormat,
                                      (unsigned long)failures.count,
                                      (unsigned long)total];
        NSString* trace =
            [failures componentsJoinedByString:@"\n\n"];
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self presentFailureAlertWithMessage:message
                                              command:@"queued downloads"
                                            failTrace:trace];
            });
    } else if (finishedItems.count > 0) {
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
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
            NSString* ext = [item[@"ext"] lowercaseString];
            NSURL* url = item[@"url"];
            if ([ext isEqualToString:@"jpg"] ||
                [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"] ||
                [ext isEqualToString:@"heic"] || [ext isEqualToString:@"webp"] ||
                [ext isEqualToString:@"gif"]) {
                // Images use the image PhotoKit API, not the video one.
                [[PHPhotoLibrary sharedPhotoLibrary]
                    performChangesAndWait:^{
                        [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:url];
                    }
                                    error:nil];
            } else {
                [BHTManager save:url];
            }
        }
        // Pill confirmation at the top.
        NSString* msg = items.count == 1 ? @"Saved to Photos" :
            [NSString stringWithFormat:@"%lu saved to Photos", (unsigned long)items.count];
        [NFBToast show:msg];
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
    if (sCancelButton ||
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
    sCancelButton = button;
}

- (void)hideCancelButton {
    [sCancelButton removeFromSuperview];
    sCancelButton = nil;
}

- (void)cancelCurrentDownload {
    sCancelRequested = YES;
    [self hideCancelButton];
    [sCurrentSession cancel];
    [sPendingJobs removeAllObjects];
    if (sProgressPill) {
        [sProgressPill dismiss];
        sProgressPill = nil;
    }
}

@end
