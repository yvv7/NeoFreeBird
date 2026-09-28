//
//  CountryFilterViewController.m
//  NeoFreeBird
//
//  Searchable picker for the country/region timeline filter: 10 region
//  toggles, 249 countries with multi-select, and a username exceptions
//  editor. Selections persist to NSUserDefaults and take effect on the next
//  timeline section update (the verdict cache is keyed on the sets).
//

#import "Settings/Pages/CountryFilterViewController.h"
#import "Filter/CountryFilter.h"
#import "Core/BHTBundle.h"

static NSInteger const kCFSectionRegions = 0;
static NSInteger const kCFSectionCountries = 1;
static NSInteger const kCFSectionExceptions = 2;

@interface CountryFilterViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSDictionary*>* regions;
@property (nonatomic, strong) NSArray<NSDictionary*>* countries;
@property (nonatomic, strong) NSArray<NSDictionary*>* filteredCountries;
@property (nonatomic, strong) UISearchController* searchController;
@property (nonatomic, strong) NSMutableSet<NSString*>* hiddenCountries;
@property (nonatomic, strong) NSMutableSet<NSString*>* hiddenRegions;
@end

@implementation CountryFilterViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        [CountryFilter loadDataIfNeeded];
        _regions = [CountryFilter allRegionsSorted];
        _countries = [CountryFilter allCountriesSorted];
        _filteredCountries = _countries;
        _hiddenCountries = [[CountryFilter hiddenCountries] mutableCopy];
        _hiddenRegions = [[CountryFilter hiddenRegions] mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [[BHTBundle sharedBundle] localizedStringForKey:@"COUNTRY_FILTER_TITLE"];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder =
        [[BHTBundle sharedBundle] localizedStringForKey:@"COUNTRY_FILTER_SEARCH_PLACEHOLDER"];
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CountryCell"];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController {
    NSString* query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        self.filteredCountries = self.countries;
    } else {
        NSString* lowered = [query lowercaseString];
        NSPredicate* p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary* row,
                                                              __unused NSDictionary* bindings) {
            NSString* name = [row[@"name"] lowercaseString];
            NSString* code = [row[@"code"] lowercaseString];
            return [name containsString:lowered] || [code containsString:lowered];
        }];
        self.filteredCountries = [self.countries filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == kCFSectionRegions) {
        return self.regions.count;
    }
    if (section == kCFSectionCountries) {
        return self.filteredCountries.count;
    }
    return 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    if (section == kCFSectionRegions) {
        return [bundle localizedStringForKey:@"COUNTRY_FILTER_REGIONS_HEADER"];
    }
    if (section == kCFSectionCountries) {
        return [bundle localizedStringForKey:@"COUNTRY_FILTER_COUNTRIES_HEADER"];
    }
    return [bundle localizedStringForKey:@"COUNTRY_FILTER_EXCEPTIONS_HEADER"];
}

- (NSString*)tableView:(UITableView*)tableView
    titleForFooterInSection:(NSInteger)section {
    if (section == kCFSectionCountries) {
        return [[BHTBundle sharedBundle]
            localizedStringForKey:@"COUNTRY_FILTER_COUNTRIES_FOOTER"];
    }
    if (section == kCFSectionExceptions) {
        return [[BHTBundle sharedBundle]
            localizedStringForKey:@"COUNTRY_FILTER_EXCEPTIONS_FOOTER"];
    }
    return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell =
        [tableView dequeueReusableCellWithIdentifier:@"CountryCell" forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == kCFSectionRegions) {
        NSDictionary* region = self.regions[indexPath.row];
        cell.textLabel.text =
            [NSString stringWithFormat:@"%@ (%@)", region[@"name"], region[@"mark"]];
        if ([self.hiddenRegions containsObject:region[@"code"]]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (indexPath.section == kCFSectionCountries) {
        NSDictionary* country = self.filteredCountries[indexPath.row];
        NSString* flag = country[@"flag"];
        cell.textLabel.text = flag.length > 0
                                  ? [NSString stringWithFormat:@"%@ %@", flag, country[@"name"]]
                                  : country[@"name"];
        cell.detailTextLabel.text = nil;
        if ([self.hiddenCountries containsObject:country[@"code"]]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else {
        NSUInteger count = [CountryFilter exemptHandles].count;
        cell.textLabel.text = [[BHTBundle sharedBundle]
            localizedStringForKey:@"COUNTRY_FILTER_EXCEPTIONS_TITLE"];
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (count > 0) {
            cell.textLabel.text =
                [NSString stringWithFormat:@"%@ (%lu)", cell.textLabel.text,
                                           (unsigned long)count];
        }
    }
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kCFSectionRegions) {
        NSString* code = self.regions[indexPath.row][@"code"];
        if ([self.hiddenRegions containsObject:code]) {
            [self.hiddenRegions removeObject:code];
        } else {
            [self.hiddenRegions addObject:code];
        }
        [CountryFilter setHiddenRegions:self.hiddenRegions];
        [tableView reloadRowsAtIndexPaths:@[indexPath]
                        withRowAnimation:UITableViewRowAnimationNone];
    } else if (indexPath.section == kCFSectionCountries) {
        NSString* code = self.filteredCountries[indexPath.row][@"code"];
        if ([self.hiddenCountries containsObject:code]) {
            [self.hiddenCountries removeObject:code];
        } else {
            [self.hiddenCountries addObject:code];
        }
        [CountryFilter setHiddenCountries:self.hiddenCountries];
        [tableView reloadRowsAtIndexPaths:@[indexPath]
                        withRowAnimation:UITableViewRowAnimationNone];
    } else {
        [self showExceptionsEditor];
    }
}

#pragma mark - Exceptions editor

- (void)showExceptionsEditor {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"COUNTRY_FILTER_EXCEPTIONS_TITLE"]
                         message:[bundle
                                     localizedStringForKey:@"COUNTRY_FILTER_EXCEPTIONS_PROMPT"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        NSArray* sorted = [[CountryFilter exemptHandles].allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        field.text = [sorted componentsJoinedByString:@", "];
        field.placeholder = @"username1, username2";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    __weak typeof(alert) weakAlert = alert;
    [alert addAction:[UIAlertAction
                        actionWithTitle:[bundle localizedStringForKey:@"COUNTRY_FILTER_SAVE"]
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction* _Nonnull action) {
                                    UIAlertController* strongAlert = weakAlert;
                                    if (strongAlert) {
                                        [weakSelf saveExceptionsFromAlert:strongAlert];
                                    }
                                }]];
    [alert addAction:[UIAlertAction
                        actionWithTitle:[bundle localizedStringForKey:@"COUNTRY_FILTER_CANCEL"]
                                  style:UIAlertActionStyleCancel
                                handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveExceptionsFromAlert:(UIAlertController*)alert {
    NSString* raw = alert.textFields.firstObject.text ?: @"";
    NSCharacterSet* separators =
        [NSCharacterSet characterSetWithCharactersInString:@",\n"];
    NSMutableSet<NSString*>* handles = [NSMutableSet set];
    for (NSString* piece in [raw componentsSeparatedByCharactersInSet:separators]) {
        NSString* h = [[[piece
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
            lowercaseString] stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"@"]];
        if (h.length == 0) {
            continue;
        }
        NSCharacterSet* allowed =
            [NSCharacterSet characterSetWithCharactersInString:
                                  @"abcdefghijklmnopqrstuvwxyz0123456789_"];
        if ([h rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound) {
            [handles addObject:h];
        }
    }
    if (handles.count > 200) {
        NSArray* sorted = [handles.allObjects sortedArrayUsingSelector:@selector(compare:)];
        handles = [[NSSet setWithArray:[sorted subarrayWithRange:NSMakeRange(0, 200)]]
            mutableCopy];
    }
    [CountryFilter setExemptHandles:handles];
    [self.tableView reloadData];
}

@end
