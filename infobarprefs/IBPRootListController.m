#import "IBPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

@implementation IBPRootListController

- (NSArray *)specifiers {
	if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// The pin state may have changed in the overlay
	[self reloadSpecifiers];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];
	// Make sure cfprefsd has the value before SpringBoard re-reads it
	CFPreferencesAppSynchronize(CFSTR("com.mathelord.infobar"));
	notify_post("com.mathelord.infobar/prefschanged");
}

- (void)resetPosition {
	notify_post("com.mathelord.infobar/resetposition");
}

- (void)resetAll {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringFromTableInBundle(@"Reset settings?", @"Root", bundle, nil)
	                                                               message:NSLocalizedStringFromTableInBundle(@"All InfoBar settings will be restored to their defaults.", @"Root", bundle, nil)
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Cancel", @"Root", bundle, nil) style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Reset", @"Root", bundle, nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		CFStringRef domain = CFSTR("com.mathelord.infobar");
		CFArrayRef keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		if (keys) {
			CFPreferencesSetMultiple(NULL, keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			CFRelease(keys);
		}
		CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		notify_post("com.mathelord.infobar/prefschanged");
		notify_post("com.mathelord.infobar/resetposition");
		[self reloadSpecifiers];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)openSource {
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/mathelord/infobar"] options:@{} completionHandler:nil];
}

@end
