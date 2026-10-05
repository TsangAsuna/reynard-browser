#import <Foundation/Foundation.h>
#import "Common/Common.h"

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property (nonatomic, copy) NSURL *URL;
@end

static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kReynardURLScheme = @"reynard";
static NSString *const kDefaultRedirectBundleID = @"com.apple.mobilesafari";
static NSString *const kGlobalKey = @"global";

static BOOL enabled = NO;
static BOOL globalRedirect = YES;

static void loadPrefs(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    enabled = [prefs objectForKey:kEnabledKey] ? [prefs boolForKey:kEnabledKey] : NO;
    id globalValue = [prefs objectForKey:kGlobalKey];
    globalRedirect = globalValue ? [globalValue boolValue] : YES;
}

// Wrap http(s) URLs as reynard://open?url=<encoded> so iOS routes them via
// the scheme Reynard actually claims. Reynard's SceneDelegate decodes this
// form back to the original URL. Returns nil for anything that is not a web
// link (plain app launches carry no URL at all, so browser icons stay
// launchable).
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

// Per-app redirect sources ("redirect.<bundle id>" keys, written by Reynard's
// "Default Browser Redirect" screen for any installed app or by the quick
// per-browser switches in system Settings). Only consulted when the global
// switch is off. With nothing configured, Safari is the default source so
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
        && ![bundleIdentifier isEqualToString:kReynardBundleID]
        && [self respondsToSelector:@selector(URL)]
        && [self respondsToSelector:@selector(setURL:)]) {
        if (globalRedirect || shouldRedirectBundle(bundleIdentifier)) {
            wrapped = wrapHTTPURLForReynard(self.URL);
        }
    }

    if (wrapped) {
        self.URL = wrapped;
        %orig(kReynardBundleID);
    } else {
        // Plain app launches (no web link) always open the real browser.
        %orig;
    }
}

%end
