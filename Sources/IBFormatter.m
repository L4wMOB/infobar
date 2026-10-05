#import "IBFormatter.h"
#import "IBStats.h"
#import "IBPrefs.h"

typedef NS_ENUM(NSInteger, IBLevel) {
	IBLevelNone,
	IBLevelGood,
	IBLevelWarn,
	IBLevelHigh,
	IBLevelCritical,
};

static UIColor *IBLevelColor(IBLevel level, UIColor *fallback) {
	switch (level) {
		case IBLevelGood: return [UIColor colorWithRed:0.35 green:0.90 blue:0.45 alpha:1];
		case IBLevelWarn: return [UIColor colorWithRed:1.00 green:0.85 blue:0.30 alpha:1];
		case IBLevelHigh: return [UIColor colorWithRed:1.00 green:0.58 blue:0.22 alpha:1];
		case IBLevelCritical: return [UIColor colorWithRed:1.00 green:0.35 blue:0.35 alpha:1];
		default: return fallback;
	}
}

static IBLevel IBLevelAscending(double v, double warn, double high) {
	if (v < 0) return IBLevelNone;
	if (v >= high) return IBLevelCritical;
	if (v >= warn) return IBLevelWarn;
	return IBLevelGood;
}

static IBLevel IBLevelDescending(double v, double warn, double low) {
	if (v < 0) return IBLevelNone;
	if (v <= low) return IBLevelCritical;
	if (v <= warn) return IBLevelWarn;
	return IBLevelGood;
}

static NSString *IBBytes(double bytes, int decimals) {
	if (bytes < 0) return @"–";
	const char *units[] = {"B", "KB", "MB", "GB", "TB"};
	int u = 0;
	while (bytes >= 1024 && u < 4) {
		bytes /= 1024;
		u++;
	}
	if (u == 0) decimals = 0;
	return [NSString stringWithFormat:@"%.*f %s", decimals, bytes, units[u]];
}

static NSString *IBGHz(double mhz) {
	return mhz > 0 ? [NSString stringWithFormat:@"%.2f", mhz / 1000.0] : @"–";
}

static NSString *IBDuration(NSTimeInterval t) {
	long s = (long)t;
	long d = s / 86400, h = (s / 3600) % 24, m = (s / 60) % 60;
	if (d > 0) return [NSString stringWithFormat:@"%ldd %ldh", d, h];
	if (h > 0) return [NSString stringWithFormat:@"%ldh %ldm", h, m];
	return [NSString stringWithFormat:@"%ldm", m];
}

@interface IBItem : NSObject
@property (nonatomic, copy) NSArray<NSString *> *symbols; // first available SF Symbol is used
@property (nonatomic, copy) NSString *label;              // short name when icons are off
@property (nonatomic, strong) NSMutableAttributedString *value;
@end

@implementation IBItem
@end

@implementation IBFormatter

+ (UIImage *)symbolNamed:(NSArray<NSString *> *)names size:(CGFloat)size color:(UIColor *)color {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSCache new]; });
	NSString *key = [NSString stringWithFormat:@"%@|%.1f|%@", names.firstObject, size, color];
	UIImage *cached = [cache objectForKey:key];
	if (cached) return cached;

	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
	for (NSString *name in names) {
		UIImage *img = [UIImage systemImageNamed:name withConfiguration:config];
		if (img) {
			img = [img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
			[cache setObject:img forKey:key];
			return img;
		}
	}
	return nil;
}

+ (NSAttributedString *)textForStats:(IBStats *)s prefs:(IBPrefs *)p {
	UIFont *font = [UIFont monospacedDigitSystemFontOfSize:p.fontSize weight:UIFontWeightSemibold];
	UIFont *smallFont = [UIFont monospacedDigitSystemFontOfSize:MAX(6, p.fontSize - 2) weight:UIFontWeightMedium];
	UIColor *base = p.textColor;
	BOOL collapsed = p.collapsed;
	BOOL list = p.layout == IBLayoutList && !collapsed;
	NSMutableArray<IBItem *> *items = [NSMutableArray array];

	if (collapsed && p.collapsedMode == IBCollapsedModeButtons) return [NSAttributedString new];

	IBItem * (^add)(NSArray *, NSString *) = ^IBItem *(NSArray *symbols, NSString *label) {
		IBItem *item = [IBItem new];
		item.symbols = symbols;
		item.label = label;
		item.value = [NSMutableAttributedString new];
		[items addObject:item];
		return item;
	};
	void (^append)(IBItem *, NSString *, IBLevel) = ^(IBItem *item, NSString *text, IBLevel level) {
		UIColor *c = p.colorizeValues ? IBLevelColor(level, base) : base;
		[item.value appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: c}]];
	};
	void (^appendSmall)(IBItem *, NSString *) = ^(IBItem *item, NSString *text) {
		[item.value appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: smallFont, NSForegroundColorAttributeName: [base colorWithAlphaComponent:0.75]}]];
	};

	if (collapsed) {
		// Summary: CPU, RAM and battery in %
		append(add(@[@"cpu"], @"CPU"), s.cpuUsage >= 0 ? [NSString stringWithFormat:@"%.0f%%", s.cpuUsage] : @"–", IBLevelAscending(s.cpuUsage, 50, 80));
		append(add(@[@"memorychip"], @"RAM"), s.ramUsagePercent >= 0 ? [NSString stringWithFormat:@"%.0f%%", s.ramUsagePercent] : @"–", IBLevelAscending(s.ramUsagePercent, 65, 85));
		double pct = s.batteryPercent;
		append(add(@[s.batteryCharging ? @"battery.100.bolt" : @"battery.75", @"battery.100"], @"BAT"), pct >= 0 ? [NSString stringWithFormat:@"%.0f%%", pct] : @"–", IBLevelDescending(pct, 40, 20));
	} else {
		if (p.showTime) {
			static NSDateFormatter *df;
			static dispatch_once_t once;
			dispatch_once(&once, ^{
				df = [NSDateFormatter new];
				df.dateFormat = @"HH:mm:ss";
			});
			append(add(@[@"clock"], @""), [df stringFromDate:[NSDate date]], IBLevelNone);
		}

		if (p.showCPU || p.showCPUFreq) {
			IBItem *it = add(@[@"cpu"], @"CPU");
			if (p.showCPU) append(it, s.cpuUsage >= 0 ? [NSString stringWithFormat:@"%.0f%%", s.cpuUsage] : @"–", IBLevelAscending(s.cpuUsage, 50, 80));
			if (p.showCPUFreq) {
				if (p.showCPU) append(it, @" ", IBLevelNone);
				NSString *approx = s.cpuFreqEstimated ? @"~" : @"";
				if (list && s.cpuFreqEMHz > 0 && s.cpuFreqPMHz > 0) {
					append(it, [NSString stringWithFormat:@"P %@ · E %@ GHz", IBGHz(s.cpuFreqPMHz), IBGHz(s.cpuFreqEMHz)], IBLevelNone);
				} else {
					double f = s.cpuFreqPMHz > 0 ? s.cpuFreqPMHz : s.cpuFreqEMHz;
					append(it, [NSString stringWithFormat:@"%@%@ GHz", approx, IBGHz(f)], IBLevelNone);
				}
				if (list && s.cpuFreqMaxMHz > 0) appendSmall(it, [NSString stringWithFormat:@" / max %@", IBGHz(s.cpuFreqMaxMHz)]);
			}
		}

		if (p.showCPUInfo) {
			IBItem *it = add(@[@"cpu.fill", @"cpu"], @"SoC");
			NSString *cores = s.cpuPerformanceCores > 0
				? [NSString stringWithFormat:@"%ld cores (%ldP+%ldE)", (long)s.cpuCoreCount, (long)s.cpuPerformanceCores, (long)s.cpuEfficiencyCores]
				: [NSString stringWithFormat:@"%ld cores", (long)s.cpuCoreCount];
			append(it, [NSString stringWithFormat:@"%@ · %@", s.chipName, cores], IBLevelNone);
		}

		if (p.showRAMPercent || p.showRAMGB) {
			IBItem *it = add(@[@"memorychip"], @"RAM");
			if (p.showRAMPercent) append(it, s.ramUsagePercent >= 0 ? [NSString stringWithFormat:@"%.0f%%", s.ramUsagePercent] : @"–", IBLevelAscending(s.ramUsagePercent, 65, 85));
			if (p.showRAMGB) {
				if (p.showRAMPercent) append(it, @" ", IBLevelNone);
				append(it, [NSString stringWithFormat:@"%.1f/%.1f GB", s.ramUsed / 1073741824.0, s.ramTotal / 1073741824.0], IBLevelNone);
			}
		}

		if (p.showBattery) {
			NSString *sym;
			double pct = s.batteryPercent;
			if (s.batteryCharging) sym = @"battery.100.bolt";
			else if (pct >= 88) sym = @"battery.100";
			else if (pct >= 63) sym = @"battery.75";
			else if (pct >= 38) sym = @"battery.50";
			else if (pct >= 13) sym = @"battery.25";
			else sym = @"battery.0";
			IBItem *it = add(@[sym, @"battery.100"], @"BAT");
			append(it, pct >= 0 ? [NSString stringWithFormat:@"%.0f%%", pct] : @"–", IBLevelDescending(pct, 40, 20));
			if (list && s.batteryMaxCapacity > 0 && pct >= 0)
				appendSmall(it, [NSString stringWithFormat:@"  ~%.0f mAh", s.batteryMaxCapacity * pct / 100.0]);
		}

		if (p.showBatteryTemp && s.batteryTemperature > -100) {
			IBItem *it = add(@[@"thermometer.medium", @"thermometer"], @"TMP");
			double t = s.batteryTemperature;
			NSString *text = p.useFahrenheit ? [NSString stringWithFormat:@"%.1f°F", t * 9.0 / 5.0 + 32.0] : [NSString stringWithFormat:@"%.1f°C", t];
			append(it, text, IBLevelAscending(t, 36, 42));
		}

		if (p.showBatteryPower && s.batteryVoltage > 0) {
			IBItem *it = add(@[@"bolt.fill"], @"PWR");
			append(it, [NSString stringWithFormat:@"%+.2f W", s.batteryPower], IBLevelNone);
			if (list) appendSmall(it, [NSString stringWithFormat:@"  %+.0f mA", s.batteryAmperage]);
		}

		if (p.showBatteryVoltage && s.batteryVoltage > 0) {
			append(add(@[@"bolt.horizontal.fill", @"bolt.horizontal", @"bolt"], @"V"), [NSString stringWithFormat:@"%.2f V", s.batteryVoltage], IBLevelNone);
		}

		if (p.showCharger && s.batteryExternalPower) {
			IBItem *it = add(@[@"powerplug.fill", @"powerplug", @"bolt.circle"], @"CHG");
			NSString *state = s.batteryFullyCharged ? @"Full" : (s.batteryCharging ? @"Charging" : @"Plugged in");
			if (s.chargerWatts > 0) append(it, [NSString stringWithFormat:@"%ld W ", (long)s.chargerWatts], IBLevelNone);
			append(it, state, s.batteryCharging ? IBLevelGood : IBLevelNone);
		}

		if (p.showBatteryHealth && s.batteryHealth > 0) {
			IBItem *it = add(@[@"heart.fill"], @"HP");
			append(it, [NSString stringWithFormat:@"%.0f%%", s.batteryHealth], IBLevelDescending(s.batteryHealth, 85, 75));
			if (list && s.batteryDesignCapacity > 0)
				appendSmall(it, [NSString stringWithFormat:@"  %ld/%ld mAh", (long)s.batteryMaxCapacity, (long)s.batteryDesignCapacity]);
		}

		if (p.showBatteryCycles && s.batteryCycles >= 0) {
			append(add(@[@"arrow.triangle.2.circlepath"], @"CYC"), [NSString stringWithFormat:@"%ld%@", (long)s.batteryCycles, list ? @" cycles" : @""], IBLevelNone);
		}

		if (p.showNetwork) {
			IBItem *it = add(@[@"arrow.up.arrow.down"], @"NET");
			append(it, [NSString stringWithFormat:@"↓%@/s ↑%@/s", IBBytes(s.netDownBytesPerSec, 1), IBBytes(s.netUpBytesPerSec, 1)], IBLevelNone);
		}

		if (p.showIP) {
			append(add(@[@"wifi"], @"IP"), s.wifiIPAddress ?: @"–", IBLevelNone);
		}

		if (p.showStorage && s.storageTotal > 0) {
			IBItem *it = add(@[@"internaldrive"], @"SSD");
			double freePct = (double)s.storageFree * 100.0 / (double)s.storageTotal;
			append(it, [NSString stringWithFormat:@"%@ free", IBBytes(s.storageFree, 1)], IBLevelDescending(freePct, 15, 5));
			if (list) appendSmall(it, [NSString stringWithFormat:@" / %@", IBBytes(s.storageTotal, 0)]);
		}

		if (p.showUptime && s.uptime > 0) {
			append(add(@[@"timer", @"clock.arrow.circlepath"], @"UP"), IBDuration(s.uptime), IBLevelNone);
		}

		if (p.showThermal) {
			NSString *names[] = {@"Nominal", @"Fair", @"Serious", @"Critical"};
			IBLevel levels[] = {IBLevelGood, IBLevelWarn, IBLevelHigh, IBLevelCritical};
			NSInteger st = MIN(MAX((NSInteger)s.thermalState, 0), 3);
			append(add(@[@"flame.fill", @"flame"], @"THR"), names[st], levels[st]);
		}
	}

	// Assemble
	NSMutableAttributedString *out = [NSMutableAttributedString new];
	NSDictionary *labelAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [base colorWithAlphaComponent:0.85]};
	NSAttributedString *separator = [[NSAttributedString alloc] initWithString:(list ? @"\n" : @"   ") attributes:labelAttrs];

	for (IBItem *item in items) {
		if (out.length > 0) [out appendAttributedString:separator];
		UIImage *icon = p.useIcons ? [self symbolNamed:item.symbols size:p.fontSize * 0.9 color:base] : nil;
		if (icon) {
			NSTextAttachment *att = [NSTextAttachment new];
			att.image = icon;
			// Vertically center the symbol on the cap height
			CGSize size = icon.size;
			att.bounds = CGRectMake(0, round((font.capHeight - size.height) / 2.0), size.width, size.height);
			[out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
			[out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u00A0" attributes:labelAttrs]];
		} else if (item.label.length > 0) {
			[out appendAttributedString:[[NSAttributedString alloc] initWithString:[item.label stringByAppendingString:@"\u00A0"] attributes:labelAttrs]];
		}
		// Never wrap inside a module, only between modules
		[item.value.mutableString replaceOccurrencesOfString:@" " withString:@"\u00A0" options:0 range:NSMakeRange(0, item.value.length)];
		[out appendAttributedString:item.value];
	}

	if (out.length == 0)
		[out appendAttributedString:[[NSAttributedString alloc] initWithString:@"InfoBar" attributes:labelAttrs]];

	NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
	para.lineSpacing = list ? 2 : 0;
	// If the row doesn't fit on screen, wrap between modules
	para.lineBreakMode = NSLineBreakByWordWrapping;
	[out addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, out.length)];
	return out;
}

@end
