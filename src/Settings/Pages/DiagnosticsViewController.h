//
//  DiagnosticsViewController.h
//  NeoFreeBird
//

#import <UIKit/UIKit.h>

@class TFNTwitterAccount;

@interface DiagnosticsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) TFNTwitterAccount* account;

- (instancetype)initWithAccount:(TFNTwitterAccount*)account;

@end
