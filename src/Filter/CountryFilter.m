//
#import "Diagnostics/NFBDiagnostics.h"
//  CountryFilter.m
//  NeoFreeBird
//
//  ObjC port of x-country-filter's detection engine. Scoring mirrors the
//  extension exactly: profile location (+100), known handle (+90), tweet
//  text keywords (up to +65), single-owner language (+25); accepted when the
//  top score >= 65 with a >= 20 margin over the runner-up.
//

#import "Filter/CountryFilter.h"
#import "Core/BHTBundle.h"
#import <objc/message.h>
#import "Core/BHTSettings.h"
#import <objc/runtime.h>

static NSString* const kCFEnabledKey = @"country_filter";
static NSString* const kCFHiddenKey = @"country_filter_hidden";
static NSString* const kCFHiddenRegionsKey = @"country_filter_hidden_regions";
static NSString* const kCFExemptHandlesKey = @"country_filter_exempt_handles";
static NSString* const kCFProtectFollowingKey = @"country_filter_protect_following";

static const NSInteger kCFMinConfidence = 65;
static const NSInteger kCFMinMargin = 20;
// Strict mode: for users who want blocked countries gone aggressively.
// Lower bar, smaller margin, and single-owner language alone can trigger.
static const NSInteger kCFStrictMinConfidence = 35;
static const NSInteger kCFStrictMinMargin = 10;
static const NSInteger kCFStrictLangPoints = 35;

static NSString* const kCFStrictKey = @"country_filter_strict";

static BOOL CFStrictMode(void) {
    return [BHTSettings boolForKey:kCFStrictKey];
}

// MARK: - Guarded messaging

static id _Nullable CFPerformObject(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) {
        return nil;
    }
    id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return value;
}

static NSString* _Nullable CFStringFor(id obj, SEL sel) {
    id value = CFPerformObject(obj, sel);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// MARK: - Data

static NSDictionary* _Nullable CFDetectionData(void) {
    static NSDictionary* data;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* path = [[BHTBundle sharedBundle].mainBundle pathForResource:@"CountryDetection"
                                                                       ofType:@"json"];
        NSData* raw = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (raw) {
            data = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        }
        if (![data isKindOfClass:NSDictionary.class]) {
            data = @{};
        }
    });
    return data;
}

static NSDictionary* _Nullable CFCatalogData(void) {
    static NSDictionary* data;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* path = [[BHTBundle sharedBundle].mainBundle pathForResource:@"CountryCatalog"
                                                                       ofType:@"json"];
        NSData* raw = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (raw) {
            data = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        }
        if (![data isKindOfClass:NSDictionary.class]) {
            data = @{};
        }
    });
    return data;
}

// Ports the extension's wordRegex(): (^|[^\p{L}\p{N}])escaped([^\p{L}\p{N}]|$)
static NSRegularExpression* _Nullable CFWordRegex(NSString* word) {
    NSString* pattern =
        [NSString stringWithFormat:@"(^|[^\\p{L}\\p{N}])%@([^\\p{L}\\p{N}]|$)",
                                   [NSRegularExpression escapedPatternForString:word]];
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive
                                                       error:nil];
}

@interface CFPattern : NSObject
@property (nonatomic, copy) NSString* country;
@property (nonatomic, copy) NSString* word;
@property (nonatomic, strong) NSRegularExpression* regex;
@end

@implementation CFPattern
@end

static NSArray<CFPattern*>* CFPlacePatterns(void) {
    static NSArray<CFPattern*>* patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<CFPattern*>* list = [NSMutableArray array];
        NSDictionary* countries = CFDetectionData()[@"countries"];
        for (NSString* code in countries) {
            for (NSString* place in (NSArray*)countries[code][@"places"]) {
                if (![place isKindOfClass:NSString.class] || place.length == 0) {
                    continue;
                }
                NSRegularExpression* re = CFWordRegex(place);
                if (!re) {
                    continue;
                }
                CFPattern* p = [CFPattern new];
                p.country = code;
                p.word = place;
                p.regex = re;
                [list addObject:p];
            }
        }
        patterns = [list copy];
    });
    return patterns;
}

static NSArray<CFPattern*>* CFKeywordPatterns(void) {
    static NSArray<CFPattern*>* patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<CFPattern*>* list = [NSMutableArray array];
        NSDictionary* countries = CFDetectionData()[@"countries"];
        for (NSString* code in countries) {
            for (NSString* keyword in (NSArray*)countries[code][@"keywords"]) {
                if (![keyword isKindOfClass:NSString.class] || keyword.length == 0) {
                    continue;
                }
                NSRegularExpression* re = CFWordRegex(keyword);
                if (!re) {
                    continue;
                }
                CFPattern* p = [CFPattern new];
                p.country = code;
                p.word = keyword;
                p.regex = re;
                [list addObject:p];
            }
        }
        patterns = [list copy];
    });
    return patterns;
}

static NSDictionary<NSString*, NSString*>* CFHandleToCountry(void) {
    static NSDictionary* map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary* m = [NSMutableDictionary dictionary];
        NSDictionary* countries = CFDetectionData()[@"countries"];
        for (NSString* code in countries) {
            for (NSString* handle in (NSArray*)countries[code][@"handles"]) {
                if ([handle isKindOfClass:NSString.class]) {
                    m[[handle lowercaseString]] = code;
                }
            }
        }
        map = [m copy];
    });
    return map;
}

static NSDictionary<NSString*, NSArray<NSString*>*>* CFLangToCountries(void) {
    static NSDictionary* map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString*, NSMutableArray*>* m = [NSMutableDictionary dictionary];
        NSDictionary* countries = CFDetectionData()[@"countries"];
        for (NSString* code in countries) {
            for (NSString* lang in (NSArray*)countries[code][@"langs"]) {
                if (![lang isKindOfClass:NSString.class]) {
                    continue;
                }
                NSString* key = [lang lowercaseString];
                NSMutableArray* owners = m[key];
                if (!owners) {
                    owners = [NSMutableArray array];
                    m[key] = owners;
                }
                [owners addObject:code];
            }
        }
        map = [m copy];
    });
    return map;
}

static NSDictionary<NSString*, NSString*>* CFCountryToRegion(void) {
    static NSDictionary* map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary* m = [NSMutableDictionary dictionary];
        NSDictionary* catalog = CFCatalogData();
        for (NSString* code in catalog) {
            NSString* region = catalog[code][@"region"];
            if ([region isKindOfClass:NSString.class]) {
                m[code] = region;
            }
        }
        map = [m copy];
    });
    return map;
}

static NSRegularExpression* CFUSStateRegex(void) {
    static NSRegularExpression* re;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        re = [NSRegularExpression
            regularExpressionWithPattern:
                @"(?:,\\s*|\\s)(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\\s*$"
                                   options:NSRegularExpressionCaseInsensitive
                                     error:nil];
    });
    return re;
}

static BOOL CFRegexMatches(NSRegularExpression* re, NSString* text) {
    if (!re || text.length == 0) {
        return NO;
    }
    NSRange range = NSMakeRange(0, text.length);
    return [re numberOfMatchesInString:text options:0 range:range] > 0;
}

// MARK: - Detection

// Ports resolveLocationToCountry(): a trailing US state abbreviation wins;
// otherwise the longest matching place string decides.
static NSString* _Nullable CFResolveLocation(NSString* _Nullable location) {
    if (location.length == 0) {
        return nil;
    }
    if (CFRegexMatches(CFUSStateRegex(), location)) {
        return @"US";
    }
    NSString* bestCountry = nil;
    NSUInteger bestLength = 0;
    for (CFPattern* p in CFPlacePatterns()) {
        if (p.word.length > bestLength && CFRegexMatches(p.regex, location)) {
            bestCountry = p.country;
            bestLength = p.word.length;
        }
    }
    return bestCountry;
}

static void CFAddEvidence(NSMutableDictionary<NSString*, NSMutableDictionary*>* scores,
                          NSString* _Nullable country, NSInteger points) {
    if (country.length == 0) {
        return;
    }
    NSMutableDictionary* entry = scores[country];
    if (!entry) {
        entry = [@{@"score": @0} mutableCopy];
        scores[country] = entry;
    }
    entry[@"score"] = @(MIN(100, [entry[@"score"] integerValue] + points));
}

@implementation CountryFilter

+ (void)loadDataIfNeeded {
    CFDetectionData();
    CFCatalogData();
    CFPlacePatterns();
    CFKeywordPatterns();
    CFHandleToCountry();
    CFLangToCountries();
    CFCountryToRegion();
}

+ (BOOL)isEnabled {
    return [BHTSettings boolForKey:kCFEnabledKey];
}

+ (nullable NSString*)detectCountryForHandle:(nullable NSString*)handle
                                    location:(nullable NSString*)location
                                        text:(nullable NSString*)text
                                        lang:(nullable NSString*)lang {
    NSMutableDictionary<NSString*, NSMutableDictionary*>* scores =
        [NSMutableDictionary dictionary];

    NSString* locationCountry = CFResolveLocation(location);
    if (locationCountry) {
        CFAddEvidence(scores, locationCountry, 100);
    }

    NSString* loweredHandle = [handle lowercaseString];
    NSString* handleCountry = loweredHandle ? CFHandleToCountry()[loweredHandle] : nil;
    if (handleCountry) {
        CFAddEvidence(scores, handleCountry, 90);
    }

    if (text.length > 0) {
        // Group matches per country first, mirroring the extension's
        // per-country keyword tally.
        NSMutableDictionary<NSString*, NSNumber*>* matchCounts =
            [NSMutableDictionary dictionary];
        for (CFPattern* p in CFKeywordPatterns()) {
            if (CFRegexMatches(p.regex, text)) {
                matchCounts[p.country] = @([matchCounts[p.country] integerValue] + 1);
            }
        }
        for (NSString* code in matchCounts) {
            NSInteger n = [matchCounts[code] integerValue];
            CFAddEvidence(scores, code, MIN(65, 35 + (n - 1) * 15));
        }
    }

    if (lang.length > 0) {
        NSString* base = [[[lang componentsSeparatedByString:@"-"] firstObject] lowercaseString];
        if (![base isEqualToString:@"en"]) {
            NSArray<NSString*>* owners = CFLangToCountries()[base];
            if (owners.count == 1) {
                CFAddEvidence(scores, owners[0], CFStrictMode() ? kCFStrictLangPoints : 25);
            }
        }
    }

    NSArray* ranked = [scores.allKeys
        sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
            NSInteger sa = [scores[a][@"score"] integerValue];
            NSInteger sb = [scores[b][@"score"] integerValue];
            if (sa != sb) {
                return sa < sb ? NSOrderedDescending : NSOrderedAscending;
            }
            return [a compare:b];
        }];
    if (ranked.count == 0) {
        return nil;
    }
    NSString* top = ranked[0];
    NSInteger topScore = [scores[top][@"score"] integerValue];
    NSInteger minConfidence = CFStrictMode() ? kCFStrictMinConfidence : kCFMinConfidence;
    NSInteger minMargin = CFStrictMode() ? kCFStrictMinMargin : kCFMinMargin;
    if (topScore < minConfidence) {
        return nil;
    }
    if (ranked.count > 1) {
        NSString* runnerUp = ranked[1];
        NSInteger runnerScore = [scores[runnerUp][@"score"] integerValue];
        if (topScore - runnerScore < minMargin) {
            return nil;
        }
    }
    return top;
}

+ (nullable NSString*)regionForCountry:(NSString*)countryCode {
    return CFCountryToRegion()[countryCode];
}

// MARK: - View-model verdict

// Tri-state follow field: 0 unknown, 1 following, 2 not following.
static BOOL CFViewModelAuthorIsFollowed(id viewModel) {
    SEL sel = @selector(representedFromUserFollowedByCurrentAccountState);
    if (![viewModel respondsToSelector:sel]) {
        return NO;
    }
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(viewModel, sel);
    return state == 1;
}

+ (BOOL)shouldHideViewModel:(id)viewModel
            hiddenCountries:(NSSet<NSString*>*)hiddenCountries
              hiddenRegions:(NSSet<NSString*>*)hiddenRegions
              exemptHandles:(NSSet<NSString*>*)exemptHandles
           protectFollowing:(BOOL)protectFollowing {
    if (hiddenCountries.count == 0 && hiddenRegions.count == 0) {
        return NO;
    }

    id user = CFPerformObject(viewModel, @selector(representedFromUser));
    NSString* handle = [[CFStringFor(user, @selector(screenName)) lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (handle.length == 0) {
        return NO;
    }

    // Exemptions first: they override every country/region filter.
    if (protectFollowing && CFViewModelAuthorIsFollowed(viewModel)) {
        return NO;
    }
    if ([exemptHandles containsObject:handle]) {
        return NO;
    }

    NSString* location = CFStringFor(user, @selector(location));

    NSString* text = nil;
    NSString* lang = nil;
    id status = CFPerformObject(viewModel, @selector(representedStatus));
    if (status) {
        text = CFStringFor(status, @selector(fullText));
        if (!text) {
            text = CFStringFor(status, @selector(text));
        }
        if (!text) {
            text = CFStringFor(status, @selector(displayText));
        }
        lang = CFStringFor(status, @selector(lang));
    }

    NSString* country = [self detectCountryForHandle:handle
                                            location:location
                                                text:text
                                                lang:lang];
    if (!country) {
        return NO;
    }
    BOOL hide = [hiddenCountries containsObject:country];
    NSString* region = hide ? nil : [self regionForCountry:country];
    if (!hide && region) {
        hide = [hiddenRegions containsObject:region];
    }
    if (hide) {
        NFBLog(@"country filter: hid @%@ (country=%@ region=%@)", handle,
              country, region ?: @"-");
    }
    return hide;
}

// MARK: - Settings

+ (NSSet<NSString*>*)hiddenCountries {
    NSArray* raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kCFHiddenKey];
    return [NSSet setWithArray:raw ?: @[]];
}

+ (NSSet<NSString*>*)hiddenRegions {
    NSArray* raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kCFHiddenRegionsKey];
    return [NSSet setWithArray:raw ?: @[]];
}

+ (NSSet<NSString*>*)exemptHandles {
    NSArray* raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kCFExemptHandlesKey];
    NSMutableSet* out = [NSMutableSet set];
    for (id h in raw ?: @[]) {
        if ([h isKindOfClass:NSString.class] && [(NSString*)h length] > 0) {
            [out addObject:[(NSString*)h lowercaseString]];
        }
    }
    return [out copy];
}

+ (BOOL)protectFollowing {
    return [BHTSettings boolForKey:kCFProtectFollowingKey];
}

+ (void)setHiddenCountries:(NSSet<NSString*>*)codes {
    [[NSUserDefaults standardUserDefaults]
        setObject:[codes.allObjects sortedArrayUsingSelector:@selector(compare:)]
           forKey:kCFHiddenKey];
}

+ (void)setHiddenRegions:(NSSet<NSString*>*)codes {
    [[NSUserDefaults standardUserDefaults]
        setObject:[codes.allObjects sortedArrayUsingSelector:@selector(compare:)]
           forKey:kCFHiddenRegionsKey];
}

+ (void)setExemptHandles:(NSSet<NSString*>*)handles {
    [[NSUserDefaults standardUserDefaults]
        setObject:[handles.allObjects sortedArrayUsingSelector:@selector(compare:)]
           forKey:kCFExemptHandlesKey];
}

// MARK: - Picker data

+ (NSArray<NSDictionary*>*)allCountriesSorted {
    static NSArray* list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary* detection = CFDetectionData()[@"countries"] ?: @{};
        NSDictionary* catalog = CFCatalogData();
        NSMutableArray* rows = [NSMutableArray array];
        for (NSString* code in catalog) {
            NSString* name = catalog[code][@"name"];
            if (![name isKindOfClass:NSString.class]) {
                continue;
            }
            NSString* region = CFCountryToRegion()[code];
            NSString* flag = detection[code][@"flag"];
            [rows addObject:@{
                @"code": code,
                @"name": name,
                @"flag": [flag isKindOfClass:NSString.class] ? flag : @"",
                @"region": [region isKindOfClass:NSString.class] ? region : @""
            }];
        }
        list = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                                   NSDictionary* b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    });
    return list;
}

+ (NSArray<NSDictionary*>*)allRegionsSorted {
    static NSArray* list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary* regions = CFDetectionData()[@"regions"] ?: @{};
        NSMutableArray* rows = [NSMutableArray array];
        for (NSString* code in regions) {
            NSString* name = regions[code][@"name"];
            if (![name isKindOfClass:NSString.class]) {
                continue;
            }
            NSString* mark = regions[code][@"mark"];
            [rows addObject:@{
                @"code": code,
                @"name": name,
                @"mark": [mark isKindOfClass:NSString.class] ? mark : @""
            }];
        }
        // Keep the extension's region order (North America first, Oceania last).
        NSArray* order = @[
            @"NORTH_AMERICA", @"LATIN_AMERICA", @"EUROPE", @"AFRICA", @"MIDDLE_EAST",
            @"CENTRAL_ASIA", @"SOUTH_ASIA", @"EAST_ASIA", @"SOUTHEAST_ASIA", @"OCEANIA"
        ];
        list = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                                   NSDictionary* b) {
            NSUInteger ia = [order indexOfObject:a[@"code"]];
            NSUInteger ib = [order indexOfObject:b[@"code"]];
            if (ia == NSNotFound) {
                ia = NSUIntegerMax;
            }
            if (ib == NSNotFound) {
                ib = NSUIntegerMax;
            }
            if (ia != ib) {
                return ia < ib ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    });
    return list;
}

@end
