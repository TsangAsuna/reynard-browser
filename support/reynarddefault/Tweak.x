#import <Foundation/Foundation.h>
#import "Common/Common.h"

// Real class shapes (iOS 14–16 runtime headers, FrontBoardServices):
// FBSystemServiceOpenApplicationRequest carries only bundleIdentifier /
// options / clientProcess / trusted. The web link of an open lives in the
// options payload, exposed by FBSOpenApplicationOptions' readonly "url"
// property (lowercase). Swapping the bundle identifier leaves the payload
// untouched, so the opened app receives the original URL directly —
// Reynard's SceneDelegate handles plain http(s) URLs.
@interface FBSOpenApplicationOptions : NSObject
@property (nonatomic, readonly) NSURL *url;
@end

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) FBSOpenApplicationOptions *options;
@end

static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
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

// Only open requests that actually carry a web link in their options are
// hijacked. Plain browser launches (icon taps: options without a URL) always
// open the real browser.
- (void)setBundleIdentifier:(NSString *)bundleIdentifier {
    loadPrefs();
    BOOL redirect = NO;
    if (enabled
        && bundleIdentifier != nil
        && ![bundleIdentifier isEqualToString:kReynardBundleID]
        && (globalRedirect || shouldRedirectBundle(bundleIdentifier))) {
        NSURL *webURL = nil;
        FBSOpenApplicationOptions *options = [self options];
        if ([options respondsToSelector:@selector(url)]) {
            webURL = [options url];
        }
        redirect = isWebLinkURL(webURL);
    }

    if (redirect) {
        %orig(kReynardBundleID);
    } else {
        %orig;
    }
}

%end
