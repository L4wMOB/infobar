#import "IBPrefs.h"

static id IBValue(NSDictionary *d, NSString *key) {
	id v = d[key];
	return [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL IBBool(NSDictionary *d, NSString *key, BOOL fallback) {
	id v = IBValue(d, key);
	return v ? [v boolValue] : fallback;
}

static double IBDouble(NSDictionary *d, NSString *key, double fallback, double min, double max) {
	id v = IBValue(d, key);
	if (!v) return fallback;
	double x = [v doubleValue];
	if (isnan(x)) return fallback;
	return MIN(MAX(x, min), max);
}

static UIColor *IBColorNamed(NSString *name) {
	NSDictionary<NSString *, UIColor *> *colors = @{
		@"white": [UIColor whiteColor],
		@"green": [UIColor colorWithRed:0.30 green:0.95 blue:0.45 alpha:1],
		@"cyan": [UIColor colorWithRed:0.35 green:0.85 blue:1.00 alpha:1],
		@"yellow": [UIColor colorWithRed:1.00 green:0.90 blue:0.30 alpha:1],
		@"orange": [UIColor colorWithRed:1.00 green:0.62 blue:0.20 alpha:1],
		@"pink": [UIColor colorWithRed:1.00 green:0.45 blue:0.75 alpha:1],
		@"purple": [UIColor colorWithRed:0.72 green:0.55 blue:1.00 alpha:1],
	};
	return colors[name] ?: [UIColor whiteColor];
}

@implementation IBPrefs

+ (NSDictionary *)rawDictionary {
	CFStringRef domain = (__bridge CFStringRef)IB_PREFS_DOMAIN;
	CFPreferencesAppSynchronize(domain);
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	CFArrayRef keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (keys) {
		CFDictionaryRef values = CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		if (values) {
			[dict addEntriesFromDictionary:(__bridge NSDictionary *)values];
			CFRelease(values);
		}
		CFRelease(keys);
	}
	return dict;
}

+ (instancetype)load {
	return [[self alloc] initWithDictionary:[self rawDictionary]];
}

- (instancetype)initWithDictionary:(NSDictionary *)d {
	if ((self = [super init])) {
		_enabled = IBBool(d, @"enabled", YES);
		_pinned = IBBool(d, @"pinned", NO);
		_showPinButton = IBBool(d, @"showPinButton", YES);
		_showOnLockScreen = IBBool(d, @"showOnLockScreen", YES);
		_hideInLandscape = IBBool(d, @"hideInLandscape", NO);
		_doubleTapTogglesLayout = IBBool(d, @"doubleTapTogglesLayout", YES);
		_collapsed = IBBool(d, @"collapsed", NO);
		_showCollapseButton = IBBool(d, @"showCollapseButton", YES);
		_collapsedMode = (IBCollapsedMode)IBDouble(d, @"collapsedMode", IBCollapsedModeSummary, 0, 1);
		_collapsedShowTime = IBBool(d, @"collapsedShowTime", NO);
		_collapsedShowCPU = IBBool(d, @"collapsedShowCPU", YES);
		_collapsedShowRAM = IBBool(d, @"collapsedShowRAM", YES);
		_collapsedShowBattery = IBBool(d, @"collapsedShowBattery", YES);
		_collapsedShowTemp = IBBool(d, @"collapsedShowTemp", NO);
		_collapsedShowNetwork = IBBool(d, @"collapsedShowNetwork", NO);
		_collapsedShowStorage = IBBool(d, @"collapsedShowStorage", NO);
		_collapsedShowUptime = IBBool(d, @"collapsedShowUptime", NO);
		_collapsedShowThermal = IBBool(d, @"collapsedShowThermal", NO);
		_updateInterval = IBDouble(d, @"updateInterval", 1.0, 0.5, 10.0);
		_position = CGPointMake(IBDouble(d, @"posX", -1, -1, 1), IBDouble(d, @"posY", -1, -1, 1));

		_layout = (IBLayout)IBDouble(d, @"layout", IBLayoutRow, 0, 1);
		_useIcons = IBBool(d, @"useIcons", YES);
		_colorizeValues = IBBool(d, @"colorizeValues", YES);
		_useBlur = IBBool(d, @"useBlur", YES);
		_fontSize = IBDouble(d, @"fontSize", 11, 7, 24);
		_backgroundAlpha = IBDouble(d, @"backgroundAlpha", 0.55, 0, 1);
		_cornerRadius = IBDouble(d, @"cornerRadius", 10, 0, 30);
		id color = IBValue(d, @"textColor");
		_textColor = IBColorNamed([color isKindOfClass:[NSString class]] ? color : @"white");
		_useFahrenheit = IBBool(d, @"useFahrenheit", NO);
		_bgExtendTop = IBDouble(d, @"bgExtendTop", 0, 0, 40);
		_bgExtendBottom = IBDouble(d, @"bgExtendBottom", 0, 0, 40);
		_graphHeight = IBDouble(d, @"graphHeight", 22, 12, 60);
		_graphWidth = IBDouble(d, @"graphWidth", 60, 30, 140);
		_shadowStrength = IBDouble(d, @"shadowStrength", 0.9, 0, 1);

		_showTime = IBBool(d, @"showTime", NO);
		_showCPU = IBBool(d, @"showCPU", YES);
		_showCPUFreq = IBBool(d, @"showCPUFreq", YES);
		_showCPUInfo = IBBool(d, @"showCPUInfo", NO);
		_showRAMPercent = IBBool(d, @"showRAMPercent", YES);
		_showRAMGB = IBBool(d, @"showRAMGB", YES);
		_showBattery = IBBool(d, @"showBattery", YES);
		_showBatteryTemp = IBBool(d, @"showBatteryTemp", YES);
		_showBatteryPower = IBBool(d, @"showBatteryPower", YES);
		_showBatteryVoltage = IBBool(d, @"showBatteryVoltage", NO);
		_showCharger = IBBool(d, @"showCharger", YES);
		_showBatteryHealth = IBBool(d, @"showBatteryHealth", NO);
		_showBatteryCycles = IBBool(d, @"showBatteryCycles", NO);
		_showNetwork = IBBool(d, @"showNetwork", YES);
		_showIP = IBBool(d, @"showIP", NO);
		_showStorage = IBBool(d, @"showStorage", NO);
		_showUptime = IBBool(d, @"showUptime", NO);
		_showThermal = IBBool(d, @"showThermal", NO);

		_showCPUGraph = IBBool(d, @"showCPUGraph", NO);
		_showRAMGraph = IBBool(d, @"showRAMGraph", NO);
		_showChargeGraph = IBBool(d, @"showChargeGraph", NO);
		_showTempGraph = IBBool(d, @"showTempGraph", NO);
		_showCyclesGraph = IBBool(d, @"showCyclesGraph", NO);
		_showNetworkGraph = IBBool(d, @"showNetworkGraph", NO);
	}
	return self;
}

+ (void)setValue:(id)value forKey:(NSString *)key {
	CFStringRef domain = (__bridge CFStringRef)IB_PREFS_DOMAIN;
	CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

@end
