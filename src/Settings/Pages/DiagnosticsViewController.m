//
//  DiagnosticsViewController.m
//  NeoFreeBird
//
//  In-app viewer for the NFB diagnostic log. Lets the user copy the log
//  (to send for debugging) without needing a Mac or syslog access.
//

#import "Settings/Pages/DiagnosticsViewController.h"
#import "Diagnostics/NFBDiagnostics.h"
#import "Core/BHTBundle.h"

@interface DiagnosticsViewController ()

@property (nonatomic, strong) UITableView* tableView;
@property (nonatomic, strong) NSArray<NSString*>* lines;

@end

@implementation DiagnosticsViewController

- (instancetype)initWithAccount:(TFNTwitterAccount*)account {
    self = [super init];
    if (self) {
        _account = account;
        self.title = [[BHTBundle sharedBundle]
            localizedStringForKey:@"DIAGNOSTICS_TITLE"];
        if (!self.title) {
            self.title = @"Diagnostics";
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                 target:self
                                 action:@selector(copyLog)],
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                 target:self
                                 action:@selector(clearLog)],
    ];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                 style:UITableViewStylePlain];
    self.tableView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [self reloadLines];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLines];
}

- (void)reloadLines {
    self.lines = NFBDiagnosticLines();
    [self.tableView reloadData];
    if (self.lines.count > 0) {
        NSIndexPath* last =
            [NSIndexPath indexPathForRow:self.lines.count - 1 inSection:0];
        [self.tableView scrollToRowAtIndexPath:last
                              atScrollPosition:UITableViewScrollPositionBottom
                                      animated:NO];
    }
}

- (void)copyLog {
    NSString* text = [self.lines componentsJoinedByString:@"\n"];
    if (text.length == 0) {
        text = @"(log is empty)";
    }
    [UIPasteboard generalPasteboard].string = text;
}

- (void)clearLog {
    NFBClearDiagnostics();
    [self reloadLines];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lines.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    static NSString* cellId = @"NFBDiagnosticCell";
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellId];
        cell.textLabel.font =
            [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = self.lines[indexPath.row];
    return cell;
}

@end
