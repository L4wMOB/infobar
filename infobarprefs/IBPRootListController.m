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
	NSString *key = [specifier propertyForKey:@"key"];
	if ([key hasPrefix:@"collapsedShow"] && [value boolValue] && [self collapsedValueCount] >= 4) {
		// The collapsed bar shows at most 4 values
		[self reloadSpecifier:specifier animated:YES];
		NSBundle *bundle = [NSBundle bundleForClass:[self class]];
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringFromTableInBundle(@"Maximum 4 values", @"Root", bundle, nil)
		                                                               message:NSLocalizedStringFromTableInBundle(@"Turn off another value first.", @"Root", bundle, nil)
		                                                        preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	[super setPreferenceValue:value specifier:specifier];
	// Make sure cfprefsd has the value before SpringBoard re-reads it
	CFPreferencesAppSynchronize(CFSTR("com.mathelord.infobar"));
	notify_post("com.mathelord.infobar/prefschanged");
}

- (NSInteger)collapsedValueCount {
	NSInteger count = 0;
	for (PSSpecifier *spec in [self specifiers]) {
		NSString *key = [spec propertyForKey:@"key"];
		if (![key hasPrefix:@"collapsedShow"]) continue;
		if ([[self readPreferenceValue:spec] boolValue]) count++;
	}
	return count;
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
