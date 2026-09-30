//
//  NFBToast.m
//  NeoFreeBird
//

#import "Core/NFBToast.h"

@implementation NFBToast

+ (void)show:(NSString*)message {
    [self show:message duration:1.1];
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

        // Clean up any existing toasts (88235) or progress pills (88234) so they never overlap
        for (UIView* sub in window.subviews) {
            if (sub.tag == 88234 || sub.tag == 88235) {
                [sub removeFromSuperview];
            }
        }

        // Haptic feedback on toast presentation
        UINotificationFeedbackGenerator* haptic = [[UINotificationFeedbackGenerator alloc] init];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        // Frosted glass pill container
        UIBlurEffect* blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        UIVisualEffectView* pill = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        pill.tag = 88235;
        pill.layer.cornerRadius = 20;
        pill.layer.masksToBounds = YES;
        pill.layer.borderWidth = 0.5;
        pill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, -28);

        // Checkmark + label
        UILabel* label = [[UILabel alloc] init];
        label.text = [NSString stringWithFormat:@"✓  %@", message];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        [pill.contentView addSubview:label];

        label.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-10],
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

        // Fast, fluid spring in, hold, and smooth slide out
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.8
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
                                     [UIView animateWithDuration:0.25
                                                           delay:0
                                                         options:UIViewAnimationOptionCurveEaseIn
                                                      animations:^{
                                                          pill.alpha = 0;
                                                          pill.transform = CGAffineTransformMakeTranslation(0, -18);
                                                      }
                                                      completion:^(__unused BOOL f2) {
                                                          [pill removeFromSuperview];
                                                      }];
                                 });
                         }];
    });
}


@end
