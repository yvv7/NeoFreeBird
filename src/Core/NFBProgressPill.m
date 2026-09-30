//
//  NFBProgressPill.m
//  NeoFreeBird
//

#import "Core/NFBProgressPill.h"
#import "ThemeColor/Palette.h"

@interface NFBProgressPill ()
@property (nonatomic, strong) UIView* pill;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* detailLabel;
@property (nonatomic, strong) UIProgressView* bar;
@end

@implementation NFBProgressPill

+ (instancetype)showWithTitle:(NSString*)title {
    NFBProgressPill* pill = [[NFBProgressPill alloc] init];
    dispatch_async(dispatch_get_main_queue(), ^{
        [pill setupWithTitle:title];
    });
    return pill;
}

- (void)setupWithTitle:(NSString*)title {
    UIWindow* window = nil;
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) {
            window = w;
            break;
        }
    }
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    if (!window) {
        return;
    }

    UIBlurEffect* blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    UIVisualEffectView* container = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    container.layer.cornerRadius = 20;
    container.layer.masksToBounds = YES;
    container.layer.borderWidth = 0.5;
    container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    container.alpha = 0;
    container.transform = CGAffineTransformMakeTranslation(0, -32);
    self.pill = container;

    UILabel* titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    self.titleLabel = titleLbl;
    [container.contentView addSubview:titleLbl];

    UIProgressView* progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progressBar.progressTintColor = [Palette currentAccentColor];
    progressBar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    progressBar.progress = 0;
    self.bar = progressBar;
    [container.contentView addSubview:progressBar];

    UILabel* detailLbl = [[UILabel alloc] init];
    detailLbl.text = @"0%";
    detailLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    detailLbl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    detailLbl.textAlignment = NSTextAlignmentCenter;
    self.detailLabel = detailLbl;
    [container.contentView addSubview:detailLbl];

    for (UIView* v in @[titleLbl, progressBar, detailLbl]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
    }
    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.topAnchor constraintEqualToAnchor:container.contentView.topAnchor constant:12],
        [titleLbl.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor constant:20],
        [titleLbl.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor constant:-20],

        [progressBar.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:8],
        [progressBar.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor constant:20],
        [progressBar.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor constant:-20],
        [progressBar.heightAnchor constraintEqualToConstant:4],

        [detailLbl.topAnchor constraintEqualToAnchor:progressBar.bottomAnchor constant:6],
        [detailLbl.leadingAnchor constraintEqualToAnchor:container.contentView.leadingAnchor constant:20],
        [detailLbl.trailingAnchor constraintEqualToAnchor:container.contentView.trailingAnchor constant:-20],
        [detailLbl.bottomAnchor constraintEqualToAnchor:container.contentView.bottomAnchor constant:-12],
    ]];

    [window addSubview:container];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:12],
        [container.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [container.widthAnchor constraintEqualToConstant:280],
    ]];

    [UIView animateWithDuration:0.45
                          delay:0
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         container.alpha = 1.0;
                         container.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)setProgress:(CGFloat)progress detail:(NSString* _Nullable)detail {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.bar.progress = progress;
        if (detail) {
            self.detailLabel.text = detail;
        } else {
            self.detailLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100];
        }
    });
}

- (void)dismissWithMessage:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UINotificationFeedbackGenerator* haptic = [[UINotificationFeedbackGenerator alloc] init];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        self.titleLabel.text = [NSString stringWithFormat:@"✓ %@", message];
        self.bar.hidden = YES;
        self.detailLabel.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [self dismiss];
                       });
    });
}

- (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
                             self.pill.alpha = 0;
                             self.pill.transform = CGAffineTransformMakeTranslation(0, -20);
                         }
                         completion:^(__unused BOOL finished) {
                             [self.pill removeFromSuperview];
                         }];
    });
}

@end

