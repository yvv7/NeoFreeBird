//
//  NFBProgressPill.m
//  NeoFreeBird
//

#import "Core/NFBProgressPill.h"

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

    UIView* container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.92];
    container.layer.cornerRadius = 18;
    container.layer.masksToBounds = YES;
    container.alpha = 0;
    self.pill = container;

    UILabel* titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    titleLbl.textColor = UIColor.whiteColor;
    titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    self.titleLabel = titleLbl;
    [container addSubview:titleLbl];

    UIProgressView* progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progressBar.progressTintColor = UIColor.systemBlueColor;
    progressBar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
    progressBar.progress = 0;
    self.bar = progressBar;
    [container addSubview:progressBar];

    UILabel* detailLbl = [[UILabel alloc] init];
    detailLbl.text = @"0%";
    detailLbl.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    detailLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    detailLbl.textAlignment = NSTextAlignmentCenter;
    self.detailLabel = detailLbl;
    [container addSubview:detailLbl];

    for (UIView* v in @[titleLbl, progressBar, detailLbl]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
    }
    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [titleLbl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [titleLbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],

        [progressBar.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:8],
        [progressBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [progressBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],

        [detailLbl.topAnchor constraintEqualToAnchor:progressBar.bottomAnchor constant:6],
        [detailLbl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [detailLbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [detailLbl.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
    ]];

    [window addSubview:container];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:12],
        [container.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [container.widthAnchor constraintEqualToConstant:280],
    ]];

    [UIView animateWithDuration:0.25
                     animations:^{
                         container.alpha = 1;
                     }];
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
        [UIView animateWithDuration:0.25
            animations:^{
                self.pill.alpha = 0;
            }
            completion:^(__unused BOOL finished) {
                [self.pill removeFromSuperview];
            }];
    });
}

@end
