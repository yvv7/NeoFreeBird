//
//  NFBToast.m
//  NeoFreeBird
//

#import "Core/NFBToast.h"

@implementation NFBToast

+ (void)show:(NSString*)message {
    [self show:message duration:2.0];
}

+ (void)show:(NSString*)message duration:(NSTimeInterval)duration {
    if (!message.length) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
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

        // Haptic feedback on toast presentation
        UINotificationFeedbackGenerator* haptic = [[UINotificationFeedbackGenerator alloc] init];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        // Frosted glass pill container
        UIBlurEffect* blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        UIVisualEffectView* pill = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        pill.layer.cornerRadius = 22;
        pill.layer.masksToBounds = YES;
        pill.layer.borderWidth = 0.5;
        pill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, -32);

        // Checkmark + label inside vibrancy effect
        UILabel* label = [[UILabel alloc] init];
        label.text = [NSString stringWithFormat:@"✓  %@", message];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        [pill.contentView addSubview:label];

        label.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:11],
            [label.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-11],
            [label.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:18],
            [label.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-18],
        ]];

        [window addSubview:pill];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [pill.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor
                                           constant:12],
            [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        ]];

        // Spring bounce in, hold, smooth spring out.
        [UIView animateWithDuration:0.45
                              delay:0
             usingSpringWithDamping:0.75
              initialSpringVelocity:0.6
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             pill.alpha = 1.0;
                             pill.transform = CGAffineTransformIdentity;
                         }
                         completion:^(__unused BOOL finished) {
                             dispatch_after(
                                 dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(duration * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), ^{
                                     [UIView animateWithDuration:0.3
                                                           delay:0
                                          usingSpringWithDamping:0.9
                                           initialSpringVelocity:0.3
                                                         options:UIViewAnimationOptionCurveEaseIn
                                                      animations:^{
                                                          pill.alpha = 0;
                                                          pill.transform = CGAffineTransformMakeTranslation(0, -20);
                                                      }
                                                      completion:^(__unused BOOL f2) {
                                                          [pill removeFromSuperview];
                                                      }];
                                 });
                         }];
    });
}


@end
