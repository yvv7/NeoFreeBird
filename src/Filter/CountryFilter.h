//
//  CountryFilter.h
//  NeoFreeBird
//
//  Country/region timeline filter, ported from the x-country-filter browser
//  extension's detection engine (MIT). Uses local signals only: profile
//  location text, known account handles, tweet text keywords, and tweet
//  language. X's "Account based in" GraphQL lookup is intentionally not
//  ported — its query hashes rotate per client and break silently.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CountryFilter : NSObject

// Master toggle state.
+ (BOOL)isEnabled;

// Loads the bundled JSON data on first use. Safe to call repeatedly.
+ (void)loadDataIfNeeded;

// Ports detectCountry() from the extension. Returns an ISO country code
// (e.g. @"US") or nil when no country reaches the confidence threshold.
+ (nullable NSString*)detectCountryForHandle:(nullable NSString*)handle
                                    location:(nullable NSString*)location
                                        text:(nullable NSString*)text
                                        lang:(nullable NSString*)lang;

// Region code (e.g. @"EUROPE") for a country code, or nil.
+ (nullable NSString*)regionForCountry:(NSString*)countryCode;

// Full per-item verdict: detect the author's country, apply the hidden
// country/region sets, and honor the exemptions (followed accounts,
// handle exceptions). All view-model access is duck-typed and guarded.
+ (BOOL)shouldHideViewModel:(id)viewModel
            hiddenCountries:(NSSet<NSString*>*)hiddenCountries
              hiddenRegions:(NSSet<NSString*>*)hiddenRegions
              exemptHandles:(NSSet<NSString*>*)exemptHandles
           protectFollowing:(BOOL)protectFollowing;

// Settings accessors (backed by NSUserDefaults).
+ (NSSet<NSString*>*)hiddenCountries;
+ (NSSet<NSString*>*)hiddenRegions;
+ (NSSet<NSString*>*)exemptHandles;
+ (BOOL)protectFollowing;

// Picker data, sorted for display.
+ (NSArray<NSDictionary*>*)allCountriesSorted; // code, name, flag, region
+ (NSArray<NSDictionary*>*)allRegionsSorted;  // code, name, mark

// Mutators for the picker.
+ (void)setHiddenCountries:(NSSet<NSString*>*)codes;
+ (void)setHiddenRegions:(NSSet<NSString*>*)codes;
+ (void)setExemptHandles:(NSSet<NSString*>*)handles;

@end

NS_ASSUME_NONNULL_END
