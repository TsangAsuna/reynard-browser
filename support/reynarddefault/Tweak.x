#import <Foundation/Foundation.h>
#import "Common/Common.h"

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property (nonatomic, copy) NSURL *URL;
@end

static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kReynardURLScheme = @"reynard";
static NSString *const kDefaultRedirectBundleID = @"com.apple.mobilesafari";

static BOOL enabled = NO;

static void loadPrefs(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    enabled = [prefs objectForKey:kEnabledKey] ? [prefs boolForKey:kEnabledKey] : NO;
}

// Wrap http(s) URLs as reynard://open?url=<encoded> so iOS routes them via
// the scheme Reynard actually claims. Reynard's SceneDelegate decodes this
// form back to the original URL.
static NSURL *wrapHTTPURLForReynard(NSURL *original) {
    NSString *scheme = original.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *encoded = [original.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!encoded) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://open?url=%@", kReynardURLScheme, encoded]];
}

// The set of redirect sources is user-defined: Reynard's "Default Browser
// Redirect" settings screen writes "redirect.<bundle id>" keys into the
// shared preference suite for any installed app (including TrollStore
// installs). The quick per-browser switches in system Settings edit the same
// keys. When nothing is configured, Safari redirects by default so that
// links other apps hand to Safari land in Reynard out of the box.
static BOOL shouldRedirectBundle(NSString *bundleIdentifier) {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
	id value = [prefs objectForKey:[@"redirect." stringByAppendingString:bundleIdentifier]];
	if (value != nil) return [value boolValue];
	return [bundleIdentifier isEqualToString:kDefaultRedirectBundleID];
}

%hook FBSystemServiceOpenApplicationRequest

- (void)setBundleIdentifier:(NSString *)bundleIdentifier {
    loadPrefs();
    NSURL *wrapped = nil;
    if (enabled
        && bundleIdentifier != nil
        && shouldRedirectBundle(bundleIdentifier)
        && [self respondsToSelector:@selector(URL)]
        && [self respondsToSelector:@selector(setURL:)]) {
        // Only web links are redirected; app-specific URL schemes pass
        // through untouched so checked apps keep working.
        wrapped = wrapHTTPURLForReynard(self.URL);
    }

    if (wrapped) {
        self.URL = wrapped;
        %orig(kReynardBundleID);
    } else {
        %orig;
    }
}

%end
