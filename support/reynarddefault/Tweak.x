#import <Foundation/Foundation.h>
#import "Common/Common.h"

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, copy) NSString *bundleIdentifier;
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

static BOOL isWebLinkURL(NSURL *url) {
    if (url == nil) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

// Wrap http(s) URLs as reynard://open?url=<encoded> so iOS routes them via
// the scheme Reynard actually claims. Reynard's SceneDelegate decodes this
// form back to the original URL (and also accepts plain http(s) URLs).
static NSURL *wrapHTTPURLForReynard(NSURL *original) {
    if (!isWebLinkURL(original)) return nil;
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *encoded = [original.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!encoded) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://open?url=%@", kReynardURLScheme, encoded]];
}

// Per-app redirect sources ("redirect.<bundle id>" keys, written by Reynard's
// "Default Browser Redirect" screen or the quick switches in system
// Settings). Only consulted when the global switch is off. With nothing
// configured, Safari is the default source so links other apps hand to
// Safari land in Reynard out of the box.
static BOOL shouldRedirectBundle(NSString *bundleIdentifier) {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
	id value = [prefs objectForKey:[@"redirect." stringByAppendingString:bundleIdentifier]];
	if (value != nil) return [value boolValue];
	return [bundleIdentifier isEqualToString:kDefaultRedirectBundleID];
}

%hook FBSystemServiceOpenApplicationRequest

// Fire on both property orders: some opens assign the URL before the bundle
// identifier, others after. Only requests that actually carry a web link are
// ever hijacked, so plain browser launches (no URL, e.g. icon taps) always
// open the real browser.
- (void)setBundleIdentifier:(NSString *)bundleIdentifier {
    loadPrefs();
    BOOL redirect = NO;
    if (enabled
        && bundleIdentifier != nil
        && ![bundleIdentifier isEqualToString:kReynardBundleID]
        && [self respondsToSelector:@selector(URL)]
        && isWebLinkURL([self URL])
        && (globalRedirect || shouldRedirectBundle(bundleIdentifier))) {
        redirect = YES;
        if ([self respondsToSelector:@selector(setURL:)]) {
            NSURL *wrapped = wrapHTTPURLForReynard([self URL]);
            if (wrapped) [self setURL:wrapped];
        }
        // Without a setURL: accessor the request keeps carrying the original
        // http(s) URL, which Reynard's SceneDelegate handles directly.
    }

    if (redirect) {
        %orig(kReynardBundleID);
    } else {
        %orig;
    }
}

- (void)setURL:(NSURL *)URL {
    %orig;
    loadPrefs();
    if (!enabled) return;
    if (![self respondsToSelector:@selector(URL)]) return;
    if (!isWebLinkURL([self URL])) return;

    NSString *bundleIdentifier = [self bundleIdentifier];
    if (bundleIdentifier == nil || [bundleIdentifier isEqualToString:kReynardBundleID]) return;
    if (globalRedirect || shouldRedirectBundle(bundleIdentifier)) {
        // Routes through the hooked setter above, which performs the swap
        // exactly once. The wrapped URL is no longer a web link, so no
        // recursion happens.
        self.bundleIdentifier = kReynardBundleID;
    }
}

%end
