//
#import "Diagnostics/NFBDiagnostics.h"
//  ImmersivePlayer.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// Declaration-only: the implementations are added to the class by Logos
// (%new) below. Without this, the compiler can't see the selectors for
// direct calls like [self bht_maybeAddImmersiveDownloadButton].
@interface _TtC14T1TwitterSwift17ImmersiveCardView (NFBImmersiveDownload)
- (void)bht_maybeAddImmersiveDownloadButton;
- (void)bht_downloadImmersiveVideo:(UIButton*)sender;
@end

// MARK: - Immersive Player Timestamp

// Field indexes in ImmersiveCardState's declaration order.
enum {
    CardStateFieldIsPanningBetweenCards = 19,
    CardStateFieldIsChromeFadedOutWhilePanning = 20,
};

static const uint8_t* immersiveCardStateMetadata(void) {
    static const uint8_t* metadata;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const void* (*getType)(const char*, size_t, const void*,
                               const void* const*) =
            dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInEnvironment");
        if (getType) {
            const char* mangledName = "14T1TwitterSwift18ImmersiveCardStateV";
            metadata = getType(mangledName, strlen(mangledName), NULL, NULL);
        }
    });
    return metadata;
}

// Reads a Bool field through the struct's field offset vector, the same way the
// app's own compiled accesses do, so byte offsets never have to be hardcoded.
static BOOL cardStateBoolField(const uint8_t* state,
                               uint32_t fieldIndex,
                               BOOL* outValue) {
    const uint8_t* metadata = immersiveCardStateMetadata();
    if (!metadata) {
        return NO;
    }

    const uint8_t* descriptor = *(const uint8_t* const*)(metadata + 8);
    uint32_t numFields = *(const uint32_t*)(descriptor + 20);
    uint32_t offsetVectorOffset = *(const uint32_t*)(descriptor + 24);
    if (fieldIndex >= numFields || offsetVectorOffset == 0) {
        return NO;
    }

    const int32_t* fieldOffsets =
        (const int32_t*)(metadata + offsetVectorOffset * sizeof(void*));
    *outValue = state[fieldOffsets[fieldIndex]] & 1;
    return YES;
}

// displayMode is a Swift enum stored as an 8-byte case index followed by a
// discriminator tag (0 = the repliesPanning payload case, 1 = an empty case).
// Empty cases: regular = 0, repliesOpen = 1, repliesCompletelyOpen = 2,
// controlsHidden = 3, scrubbing = 4, statusExpanded = 5.
static BOOL progressLabelAlphaFromState(id pluginView, CGFloat* outAlpha) {
    Ivar stateIvar = class_getInstanceVariable([pluginView class], "state");
    if (!stateIvar) {
        return NO;
    }

    uint8_t* state =
        (uint8_t*)(__bridge void*)pluginView + ivar_getOffset(stateIvar);
    uint64_t displayModeCase = *(uint64_t*)state;
    uint8_t displayModeTag = state[8];

    BOOL visible =
        displayModeTag == 1 && (displayModeCase < 1 || displayModeCase > 3);

    if (visible) {
        BOOL panning = NO, chromeFaded = NO;
        if (cardStateBoolField(state, CardStateFieldIsPanningBetweenCards,
                               &panning) &&
            panning) {
            visible = NO;
        } else if (cardStateBoolField(state,
                                      CardStateFieldIsChromeFadedOutWhilePanning,
                                      &chromeFaded) &&
                   chromeFaded) {
            visible = NO;
        }
    }

    *outAlpha = visible ? 1.0 : 0.0;
    return YES;
}


static const void* kBHTRestoredTimestampKey = &kBHTRestoredTimestampKey;

// VideoControlsView.ProgressLabelMode, a payload-free Swift enum stored in a
// single byte. The timestamp button's tap handler just flips this and rebuilds
// its configuration, so writing it has the same effect as tapping the label.
enum {
    ProgressLabelModeRemaining = 0,
    ProgressLabelModeTotal = 1,
};

%hook _TtC14T1TwitterSwift17VideoControlsView

- (void)layoutSubviews {
    %orig;

    BHTApplyDimToVideoControls(self);

    if (![BHTSettings boolForKey:@"restore_video_timestamp"] ||
        objc_getAssociatedObject(self, kBHTRestoredTimestampKey)) {
        return;
    }

    Ivar modeIvar =
        class_getInstanceVariable([self class], "progressLabelMode");
    if (!modeIvar) {
        return;
    }

    objc_setAssociatedObject(self, kBHTRestoredTimestampKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Set once instead of on every layout so tapping the label still toggles
    // back to the remaining-time countdown.
    uint8_t* mode = (uint8_t*)(__bridge void*)self + ivar_getOffset(modeIvar);
    *mode = ProgressLabelModeTotal;
}

%end

%hook _TtC14T1TwitterSwift24ImmersivePiPDropZoneView
- (void)didMoveToWindow {
    %orig;
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        self.hidden = true;
        self.alpha = 0.0;
        self.userInteractionEnabled = false;
        for (UIView* subview in self.subviews) {
            subview.hidden = true;
            subview.alpha = 0.0;
            subview.userInteractionEnabled = false;
        }
    }
}

%end

%hook T1ImmersiveViewController

- (BOOL)isCurrentCardDockEligible {
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        return NO;
    }

    return %orig;
}

%end

%hook T1ImmersiveViewControllerV2

- (BOOL)isCurrentCardDockEligible {
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        return NO;
    }

    return %orig;
}

%end

// MARK: - Disable Immersive Feed Scrolling

// The card pan drives vertical paging between videos; blocking it lets the
// swipe-down dismiss gesture take over.
static BOOL isImmersiveCardPan(id viewController,
                               UIGestureRecognizer* gesture) {
    Ivar panIvar =
        class_getInstanceVariable([viewController class], "panRecognizer");
    return panIvar && object_getIvar(viewController, panIvar) == gesture;
}

static BOOL isUpwardPan(UIGestureRecognizer *gesture) {
    if (![gesture isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
    CGPoint v = [pan velocityInView:gesture.view];
    return v.y < 0.0;
}

%hook T1ImmersiveViewController

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"] &&
        isImmersiveCardPan(self, gesture)) {
        if (isUpwardPan(gesture)) {
            return NO;
        }
        return YES;
    }

    return %orig;
}

- (BOOL)allowsUpwardSwipeToDismiss {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"]) {
        return NO;
    }

    return %orig;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"]) {
        CGPoint v = [pan velocityInView:self.view];
        if (v.y < 0.0) {
            return;
        }
    }

    %orig(pan);
}

%end

%hook T1ImmersiveViewControllerV2

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"] &&
        isImmersiveCardPan(self, gesture)) {
        if (isUpwardPan(gesture)) {
            return NO;
        }
        return YES;
    }

    return %orig;
}

- (BOOL)allowsUpwardSwipeToDismiss {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"]) {
        return NO;
    }

    return %orig;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"]) {
        CGPoint v = [pan velocityInView:self.view];
        if (v.y < 0.0) {
            return;
        }
    }

    %orig(pan);
}

%end

// MARK: - Tap to Play/Pause

static TAVPlayer* immersivePagePlayer(UIView* rootView) {
    // Fast path: the known page-view class with a "_player" ivar holding a
    // TAVPlayer (which is an NSObject wrapper, NOT an AVPlayer subclass).
    __block UIView* pageView = nil;
    Class pageViewClass = %c(_TtC14T1TwitterSwift22ImmersiveVideoPageView);
    NFBLog(@"immersive scan: fast-path class %@",
           pageViewClass ? @"found" : @"nil (X renamed it?)");
    if (pageViewClass) {
        EnumerateSubviewsRecursively(rootView, ^(UIView* view) {
            if (!pageView && [view isKindOfClass:pageViewClass]) {
                pageView = view;
            }
        });
    }
    if (pageView) {
        // The ivar is "_player" (with underscore). Try both names.
        for (NSString* ivarName in @[@"_player", @"player"]) {
            Ivar playerIvar = class_getInstanceVariable([pageView class], ivarName.UTF8String);
            id player = playerIvar ? object_getIvar(pageView, playerIvar) : nil;
            NFBLog(@"immersive scan: fast-path pageView=%@ ivar=%s player=%@",
                   NSStringFromClass([pageView class]), ivarName.UTF8String,
                   player ? NSStringFromClass([player class]) : @"nil");
            if (player && ([player isKindOfClass:objc_getClass("TAVPlayer")] ||
                           [player isKindOfClass:[AVPlayer class]])) {
                return (TAVPlayer*)player;
            }
        }
    }
    // Fallback: scan every subview's ivars for any TAVPlayer or AVPlayer.
    // Survives X renaming the page-view class or the ivar holding the player.
    __block TAVPlayer* found = nil;
    __block NSUInteger scannedViews = 0;
    EnumerateSubviewsRecursively(rootView, ^(UIView* view) {
        if (found) {
            return;
        }
        scannedViews++;
        unsigned int ivarCount = 0;
        Ivar* ivars = class_copyIvarList([view class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount && !found; i++) {
            const char* type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') {
                continue;
            }
            id value = object_getIvar(view, ivars[i]);
            if ([value isKindOfClass:objc_getClass("TAVPlayer")] ||
                [value isKindOfClass:[AVPlayer class]]) {
                found = (TAVPlayer*)value;
            }
        }
        free(ivars);
    });
    NFBLog(@"immersive scan: fallback scanned %lu views, player=%@",
           (unsigned long)scannedViews,
           found ? NSStringFromClass([found class]) : @"nil");
    return found;
}

// The URL X is actually playing, for the in-video download button.
// TAVPlayer is an NSObject wrapper (not an AVPlayer subclass). It holds the
// real AVPlayer internally. Find it via ivar introspection.
static id _Nullable NFBGetIvarByName(id obj, const char* ivarName) {
    if (!obj || !ivarName) {
        return nil;
    }
    Class cls = [obj class];
    for (int d = 0; d < 5 && cls; d++) {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (strcmp(ivar_getName(ivars[i]), ivarName) == 0) {
                id value = object_getIvar(obj, ivars[i]);
                free(ivars);
                return value;
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static AVPlayer* _Nullable BHTAVPlayerFromTAVPlayer(TAVPlayer* tavPlayer) {
    if (!tavPlayer) {
        return nil;
    }
    if ([tavPlayer isKindOfClass:[AVPlayer class]]) {
        return (AVPlayer*)tavPlayer;
    }
    // Deep chain (verified via Frida on-device):
    // TAVPlayer -> _internalState -> _items[0] -> _tech -> _avPlayer
    AVPlayer* found = nil;
    @try {
        id internalState = NFBGetIvarByName(tavPlayer, "_internalState");
        id items = internalState ? NFBGetIvarByName(internalState, "_items") : nil;
        id firstItem = ([items isKindOfClass:[NSArray class]] && [(NSArray*)items count] > 0)
                           ? [(NSArray*)items objectAtIndex:0]
                           : nil;
        id tech = firstItem ? NFBGetIvarByName(firstItem, "_tech") : nil;
        id avPlayer = tech ? NFBGetIvarByName(tech, "_avPlayer") : nil;
        if ([avPlayer isKindOfClass:[AVPlayer class]]) {
            found = (AVPlayer*)avPlayer;
            NFBLog(@"immersive download: found AVPlayer via deep chain");
        }
    } @catch (NSException* __unused ex) {
    }
    // Fallback: shallow ivar scan (old approach).
    if (!found) {
        unsigned int ivarCount = 0;
        Ivar* ivars = class_copyIvarList([tavPlayer class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount && !found; i++) {
            const char* type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') {
                continue;
            }
            id value = object_getIvar(tavPlayer, ivars[i]);
            if ([value isKindOfClass:[AVPlayer class]]) {
                found = (AVPlayer*)value;
            }
        }
        free(ivars);
    }
    NFBLog(@"immersive download: TAVPlayer=%@ internal AVPlayer=%@",
           NSStringFromClass([tavPlayer class]),
           found ? NSStringFromClass([found class]) : @"nil");
    return found;
}

// Smart filename for immersive: scan visible labels for @username.
// Returns "username_yyyyMMdd_HHmmss" or nil if not found.
static NSString* _Nullable BHTImmersiveFileBase(UIView* _Nullable rootView) {
    if (!rootView) {
        return nil;
    }
    NSString* foundHandle = nil;
    NSMutableArray<UIView*>* stack = [NSMutableArray arrayWithObject:rootView];
    while (stack.count > 0 && !foundHandle) {
        UIView* view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UILabel class]]) {
            NSString* text = [(UILabel*)view text];
            // Find @handle pattern.
            NSRange atRange = [text rangeOfString:@"@"];
            if (atRange.location != NSNotFound) {
                NSString* after = [text substringFromIndex:atRange.location + 1];
                // Handle is alphanumeric + underscore, up to whitespace.
                NSCharacterSet* allowed = [NSCharacterSet
                    characterSetWithCharactersInString:
                        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
                NSMutableString* handle = [NSMutableString new];
                for (NSUInteger i = 0; i < after.length; i++) {
                    unichar c = [after characterAtIndex:i];
                    if ([allowed characterIsMember:c]) {
                        [handle appendFormat:@"%C", c];
                    } else {
                        break;
                    }
                }
                if (handle.length > 0) {
                    foundHandle = handle;
                    break;
                }
            }
        }
        for (UIView* sub in view.subviews) {
            [stack addObject:sub];
        }
    }
    if (!foundHandle.length) {
        return nil;
    }
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString* datePart = [formatter stringFromDate:[NSDate date]];
    NSString* base = [NSString stringWithFormat:@"%@_%@", foundHandle, datePart];
    NFBLog(@"immersive download: smart filename base=%@", base);
    return base;
}

// Fallback: walk the layer hierarchy for AVPlayerLayer, whose player is a
// real AVPlayer. TAVPlayer wraps/controls playback but the actual rendering
// goes through a player layer with the real item and URL.
static NSURL* _Nullable BHTURLFromPlayerLayers(UIView* _Nullable rootView) {
    if (!rootView) {
        return nil;
    }
    NSMutableArray<CALayer*>* stack = [NSMutableArray arrayWithObject:rootView.layer];
    while (stack.count > 0) {
        CALayer* layer = stack.lastObject;
        [stack removeLastObject];
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayer* avPlayer = [(AVPlayerLayer*)layer player];
            AVPlayerItem* item = avPlayer.currentItem;
            AVAsset* asset = item.asset;
            if ([asset isKindOfClass:[AVURLAsset class]]) {
                NSURL* url = [(AVURLAsset*)asset URL];
                if (url) {
                    NFBLog(@"immersive download: found URL via AVPlayerLayer: %@",
                           url.absoluteString);
                    return url;
                }
            }
        }
        for (CALayer* sub in layer.sublayers) {
            [stack addObject:sub];
        }
    }
    return nil;
}

static NSURL* _Nullable BHTImmersivePlayingURL(TAVPlayer* _Nullable player) {
    if (!player) {
        return nil;
    }
    AVPlayerItem* item = nil;
    // Try 1: TAVPlayer might forward currentItem directly.
    if ([player respondsToSelector:@selector(currentItem)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id currentItem = [player performSelector:@selector(currentItem)];
#pragma clang diagnostic pop
        if ([currentItem isKindOfClass:[AVPlayerItem class]]) {
            item = (AVPlayerItem*)currentItem;
            NFBLog(@"immersive download: got currentItem via TAVPlayer.currentItem");
        }
    }
    // Try 2: Extract the internal AVPlayer via introspection.
    if (!item) {
        AVPlayer* avPlayer = BHTAVPlayerFromTAVPlayer(player);
        if (!avPlayer) {
            NFBLog(@"immersive download: no AVPlayer inside TAVPlayer and no currentItem");
            return nil;
        }
        item = avPlayer.currentItem;
    }
    if (!item) {
        NFBLog(@"immersive download: no current item");
        return nil;
    }
    AVAsset* asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        return [(AVURLAsset*)asset URL];
    }
    // Fallback: some X builds wrap the asset in a subclass that still
    // vends the URL. Duck-typed and guarded.
    if ([asset respondsToSelector:@selector(URL)]) {
        id url = [asset performSelector:@selector(URL)];
        if ([url isKindOfClass:NSURL.class] && [(NSURL*)url absoluteString].length > 0) {
            return (NSURL*)url;
        }
    }
    return nil;
}

// timeControlStatus follows AVPlayer: 0 paused, 1 waiting to play, 2 playing.
static void togglePlayback(TAVPlayer* player) {
    if (player.playbackState.timeControlStatus != 0) {
        [player pause];
    } else {
        [player playOrReplay];  // replays instead of no-oping at end of video
    }
}

static const void* kBHTTwoFingerTapKey = &kBHTTwoFingerTapKey;
static const void* kBHTImmersiveDownloadButtonKey =
    &kBHTImmersiveDownloadButtonKey;

%hook _TtC14T1TwitterSwift17ImmersiveCardView

- (void)didMoveToWindow {
    %orig;

    if (!self.window) {
        return;
    }

    if (!objc_getAssociatedObject(self, kBHTTwoFingerTapKey)) {
        UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(bht_handleTwoFingerTap:)];
        tap.numberOfTouchesRequired = 2;
        tap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:tap];

        objc_setAssociatedObject(self, kBHTTwoFingerTapKey, tap,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [self bht_maybeAddImmersiveDownloadButton];
}

// MARK: - In-video download button

// X's immersive "..." menu is built outside _t1_actionItemsForStatus:, so
// our "Download media" entry never appears in it and users land on X's own
// broken native downloader instead. A download button on the card itself —
// the approach shipped X tweaks use — gives the tweak a working entry point
// inside the player. One button per card view; the tap handler resolves the
// currently playing URL fresh each time, so recycled cards stay correct.
%new
- (void)bht_maybeAddImmersiveDownloadButton {
    UIButton* existing =
        objc_getAssociatedObject(self, kBHTImmersiveDownloadButtonKey);
    if (existing) {
        // X can add its chrome after us; stay on top.
        [self bringSubviewToFront:existing];
        return;
    }
    if (![BHTSettings boolForKey:@"download_videos"]) {
        return;
    }
    UIButton* dlButton = [UIButton buttonWithType:UIButtonTypeCustom];
    dlButton.translatesAutoresizingMaskIntoConstraints = NO;
    dlButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    dlButton.layer.cornerRadius = 22;
    dlButton.tintColor = UIColor.whiteColor;
    [dlButton setImage:[UIImage systemImageNamed:@"arrow.down.to.line"]
              forState:UIControlStateNormal];
    dlButton.accessibilityLabel = @"Download video";
    [dlButton addTarget:self
                 action:@selector(bht_downloadImmersiveVideo:)
       forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dlButton];
    // Top-left, below the back chevron: clear of the right-side action rail
    // and the bottom playback controls on every screen size.
    [NSLayoutConstraint activateConstraints:@[
        [dlButton.widthAnchor constraintEqualToConstant:44],
        [dlButton.heightAnchor constraintEqualToConstant:44],
        [dlButton.leadingAnchor
            constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor
                           constant:12],
        [dlButton.topAnchor
            constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                           constant:60],
    ]];
    objc_setAssociatedObject(self, kBHTImmersiveDownloadButtonKey, dlButton,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)bht_downloadImmersiveVideo:(UIButton*)sender {
    NFBLog(@"immersive download: button tapped");
    if (![BHTSettings boolForKey:@"download_videos"]) {
        NFBLog(@"immersive download: download_videos disabled, aborting");
        return;
    }
    NFBLog(@"immersive download: scanning for player...");
    TAVPlayer* player = immersivePagePlayer(self);
    NFBLog(@"immersive download: scan done, player=%@",
           player ? NSStringFromClass([player class]) : @"nil");
    NSURL* videoURL = BHTImmersivePlayingURL(player);
    // Fallback: the video renders through an AVPlayerLayer somewhere in
    // the card's hierarchy. Its player is a real AVPlayer with the URL.
    if (!videoURL) {
        NFBLog(@"immersive download: trying AVPlayerLayer fallback...");
        videoURL = BHTURLFromPlayerLayers(self);
        NFBLog(@"immersive download: layer fallback url=%@",
               videoURL.absoluteString ?: @"nil");
    }
    NFBLog(@"immersive download: URL extraction done, url=%@",
           videoURL.absoluteString ?: @"nil");
    if (!videoURL) {
        AVPlayerItem* item = [player isKindOfClass:[AVPlayer class]]
                                 ? [(AVPlayer*)player currentItem]
                                 : nil;
        NFBLog(@"immersive download: no playable URL (player=%@ item=%@ asset=%@)",
              player ? NSStringFromClass([player class]) : @"nil",
              item ? NSStringFromClass([item class]) : @"nil",
              item.asset ? NSStringFromClass([item.asset class]) : @"nil");
        NSString* alertTitle = [[BHTBundle sharedBundle]
            localizedStringForKey:@"IMMERSIVE_DOWNLOAD_ALERT_TITLE"];
        if ([alertTitle isEqualToString:@"IMMERSIVE_DOWNLOAD_ALERT_TITLE"])
            alertTitle = @"Download";
        NSString* alertMessage = [[BHTBundle sharedBundle]
            localizedStringForKey:@"IMMERSIVE_DOWNLOAD_NO_VIDEO_MESSAGE"];
        if ([alertMessage
                isEqualToString:@"IMMERSIVE_DOWNLOAD_NO_VIDEO_MESSAGE"])
            alertMessage = @"Couldn't find the playing video.";
        NSString* okLabel = [[BHTBundle sharedBundle]
            localizedStringForKey:@"OK_ACTION_LABEL"];
        if ([okLabel isEqualToString:@"OK_ACTION_LABEL"])
            okLabel = @"OK";
        UIAlertController* alert = [UIAlertController
            alertControllerWithTitle:alertTitle
                             message:alertMessage
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:okLabel
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        UIViewController* host = self.window.rootViewController;
        while (host.presentedViewController) {
            host = host.presentedViewController;
        }
        [host presentViewController:alert animated:YES completion:nil];
        return;
    }
    NFBLog(@"immersive download: %@", videoURL.absoluteString);
    static char immersiveDownloaderKey;
    DownloadInlineButton* downloader =
        objc_getAssociatedObject(self, &immersiveDownloaderKey);
    if (!downloader) {
        downloader = [DownloadInlineButton new];
        objc_setAssociatedObject(self, &immersiveDownloaderKey, downloader,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Smart filename: try to find @username in visible labels.
    NSString* fileBase = nil;
    if ([BHTSettings boolForKey:@"download_smart_filenames"]) {
        fileBase = BHTImmersiveFileBase(self);
    }
    [downloader downloadVideoAtURL:videoURL fileNameBase:fileBase];
}

%new
- (void)bht_handleTwoFingerTap:(UITapGestureRecognizer*)tap {
    if (![BHTSettings boolForKey:@"tap_to_pause"]) {
        return;
    }

    __block UIView* pageView = nil;
    EnumerateSubviewsRecursively(self, ^(UIView* view) {
        if (!pageView &&
            [view isKindOfClass:%c(_TtC14T1TwitterSwift22ImmersiveVideoPageView)]) {
            pageView = view;
        }
    });

    TAVPlayer* player = pageView ? immersivePagePlayer(pageView) : nil;
    if (!player) {
        return;
    }

    BOOL wasPlaying = player.playbackState.timeControlStatus != 0;
    togglePlayback(player);

    [self setPausedByUser:wasPlaying];
}

%end
