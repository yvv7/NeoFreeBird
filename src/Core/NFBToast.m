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
        // Find the key window.
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

        // Pill container.
        UIView* pill = [[UIView alloc] init];
        pill.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.92];
        pill.layer.cornerRadius = 22;
        pill.layer.masksToBounds = YES;
        pill.alpha = 0;

        // Checkmark + label.
        UILabel* label = [[UILabel alloc] init];
        label.text = [NSString stringWithFormat:@"✓ %@", message];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        [pill addSubview:label];

        label.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:12],
            [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-12],
            [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:20],
            [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-20],
        ]];

        [window addSubview:pill];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [pill.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor
                                           constant:12],
            [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        ]];

        // Animate in, hold, animate out.
        [UIView animateWithDuration:0.25
                         animations:^{
                             pill.alpha = 1;
                         }
                         completion:^(__unused BOOL finished) {
                             dispatch_after(
                                 dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(duration * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), ^{
                                     [UIView animateWithDuration:0.25
                                         animations:^{
                                             pill.alpha = 0;
                                         }
                                         completion:^(__unused BOOL f2) {
                                             [pill removeFromSuperview];
                                         }];
                                 });
                         }];
    });
}

@end
