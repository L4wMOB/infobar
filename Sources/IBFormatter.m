#import "IBFormatter.h"
#import "IBStats.h"
#import "IBPrefs.h"
#import "IBGraphView.h"

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

static CGFloat IBColorDistance(UIColor *a, UIColor *b) {
	CGFloat ar = 0, ag = 0, ab = 0, br = 0, bg = 0, bb = 0, al;
	[a getRed:&ar green:&ag blue:&ab alpha:&al];
	[b getRed:&br green:&bg blue:&bb alpha:&al];
	return sqrt((ar - br) * (ar - br) + (ag - bg) * (ag - bg) + (ab - bb) * (ab - bb));
}

static UIColor *IBPickDistinct(NSArray<UIColor *> *candidates, NSArray<UIColor *> *avoid) {
	for (UIColor *c in candidates) {
		BOOL ok = YES;
		for (UIColor *a in avoid) {
			if (IBColorDistance(c, a) < 0.55) { ok = NO; break; }
		}
		if (ok) return c;
	}
	return candidates.lastObject;
}

static NSString *IBPct(double v) {
	if (v < 0) return @"–";
	NSString *s = [NSString stringWithFormat:@"%.0f%%", v];
	NSInteger digits = (NSInteger)s.length - 1;
	NSMutableString *out = [s mutableCopy];
	for (NSInteger i = digits; i < 3; i++) [out appendString:@"\u2007"];
	[out appendString:@"\u2060"];
	return out;
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
@property (nonatomic, copy) NSArray<NSString *> *symbols;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSMutableAttributedString *value;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *graphSeries;
@property (nonatomic, copy) NSArray<UIColor *> *graphColors;
@property (nonatomic, copy) NSArray<UIColor *> *graphBandColors;
@property (nonatomic, copy) NSArray<NSNumber *> *graphThresholds;
@property (nonatomic, copy) NSArray<UIColor *> *graphThresholdColors;
@property (nonatomic) NSInteger graphUnit;
@property (nonatomic) double graphValueScale;
@property (nonatomic) double graphValueOffset;
@property (nonatomic) BOOL graphOnly; // only the graph, no icon / text
@property (nonatomic) double graphMin;
@property (nonatomic) double graphMax;
@property (nonatomic) double graphMinSpan;
@end

@implementation IBItem
@end

@implementation IBModule
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

+ (NSArray<IBModule *> *)modulesForStats:(IBStats *)s prefs:(IBPrefs *)p {
	UIFont *font = [UIFont monospacedDigitSystemFontOfSize:p.fontSize weight:UIFontWeightSemibold];
	UIFont *smallFont = [UIFont monospacedDigitSystemFontOfSize:MAX(6, p.fontSize - 2) weight:UIFontWeightMedium];
	UIColor *base = p.textColor;
	BOOL collapsed = p.collapsed;
	BOOL list = p.layout == IBLayoutList && !collapsed;
	NSMutableArray<IBItem *> *items = [NSMutableArray array];

	if (collapsed && p.collapsedMode == IBCollapsedModeButtons) return @[];

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

	UIColor *goodC = p.colorizeValues ? IBLevelColor(IBLevelGood, base) : base;
	UIColor *warnC = IBPickDistinct(@[IBLevelColor(IBLevelWarn, base), IBLevelColor(IBLevelHigh, base), [UIColor colorWithRed:0.30 green:0.85 blue:1.0 alpha:1]], @[goodC]);
	UIColor *critC = IBPickDistinct(@[IBLevelColor(IBLevelCritical, base), [UIColor colorWithRed:1.0 green:0.25 blue:0.75 alpha:1], [UIColor colorWithRed:0.70 green:0.40 blue:1.0 alpha:1], [UIColor whiteColor]], @[goodC, warnC]);
	void (^attachGraph)(IBItem *, NSArray *, NSArray *, double, double, double, double, double, BOOL, NSInteger) = ^(IBItem *item, NSArray *series, NSArray *colors, double min, double max, double minSpan, double t1, double t2, BOOL ascending, NSInteger unit) {
		item.graphUnit = unit;
		item.graphSeries = series;
		item.graphColors = colors;
		item.graphMin = min;
		item.graphMax = max;
		item.graphMinSpan = minSpan;
		item.graphThresholds = @[@(t1), @(t2)];
		item.graphBandColors = ascending ? @[goodC, warnC, critC] : @[critC, warnC, goodC];
		item.graphThresholdColors = ascending ? @[warnC, critC] : @[critC, warnC];
	};

	if (collapsed) {
		if (p.collapsedShowTime) {
			static NSDateFormatter *cdf;
			static dispatch_once_t conce;
			dispatch_once(&conce, ^{
				cdf = [NSDateFormatter new];
				cdf.dateFormat = @"HH:mm";
			});
			append(add(@[@"clock"], @""), [cdf stringFromDate:[NSDate date]], IBLevelNone);
		}
		if (p.collapsedShowCPU)
			append(add(@[@"cpu"], @"CPU"), IBPct(s.cpuUsage), IBLevelAscending(s.cpuUsage, 50, 80));
		if (p.collapsedShowRAM)
			append(add(@[@"memorychip"], @"RAM"), IBPct(s.ramUsagePercent), IBLevelAscending(s.ramUsagePercent, 65, 85));
		if (p.collapsedShowBattery) {
			double pct = s.batteryPercent;
			append(add(@[s.batteryCharging ? @"battery.100.bolt" : @"battery.75", @"battery.100"], @"BAT"), IBPct(pct), IBLevelDescending(pct, 40, 20));
		}
		if (p.collapsedShowTemp && s.batteryTemperature > -100) {
			double t = s.batteryTemperature;
			NSString *text = p.useFahrenheit ? [NSString stringWithFormat:@"%.0f°F", t * 9.0 / 5.0 + 32.0] : [NSString stringWithFormat:@"%.0f°C", t];
			append(add(@[@"thermometer.medium", @"thermometer"], @"TMP"), text, IBLevelAscending(t, 36, 42));
		}
		if (p.collapsedShowNetwork)
			append(add(@[@"arrow.up.arrow.down"], @"NET"), [NSString stringWithFormat:@"↓%@/s ↑%@/s", IBBytes(s.netDownBytesPerSec, 1), IBBytes(s.netUpBytesPerSec, 1)], IBLevelNone);
		if (p.collapsedShowStorage && s.storageTotal > 0) {
			double freePct = (double)s.storageFree * 100.0 / (double)s.storageTotal;
			append(add(@[@"internaldrive"], @"SSD"), IBBytes(s.storageFree, 0), IBLevelDescending(freePct, 15, 5));
		}
		if (p.collapsedShowUptime && s.uptime > 0)
			append(add(@[@"timer", @"clock.arrow.circlepath"], @"UP"), IBDuration(s.uptime), IBLevelNone);
		if (p.collapsedShowThermal) {
			NSString *names[] = {@"Nominal", @"Fair", @"Serious", @"Critical"};
			IBLevel levels[] = {IBLevelGood, IBLevelWarn, IBLevelHigh, IBLevelCritical};
			NSInteger st = MIN(MAX((NSInteger)s.thermalState, 0), 3);
			append(add(@[@"flame.fill", @"flame"], @"THR"), names[st], levels[st]);
		}
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

		if (p.showCPU || p.showCPUFreq || p.showCPUGraph) {
			IBItem *it = add(@[@"cpu"], @"CPU");
			it.graphOnly = !(p.showCPU || p.showCPUFreq);
			BOOL cpuPercent = p.showCPU;
			if (cpuPercent) append(it, IBPct(s.cpuUsage), IBLevelAscending(s.cpuUsage, 50, 80));
			if (p.showCPUGraph) attachGraph(it, @[[s historyForSeries:IBSeriesCPU]], @[goodC], 0, 100, 100, 50, 80, YES, IBGraphUnitPercent);
			if (p.showCPUFreq) {
				if (cpuPercent) append(it, @" ", IBLevelNone);
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

		if (p.showRAMPercent || p.showRAMGB || p.showRAMGraph) {
			IBItem *it = add(@[@"memorychip"], @"RAM");
			it.graphOnly = !(p.showRAMPercent || p.showRAMGB);
			BOOL ramPercent = p.showRAMPercent;
			if (ramPercent) append(it, IBPct(s.ramUsagePercent), IBLevelAscending(s.ramUsagePercent, 65, 85));
			if (p.showRAMGraph) attachGraph(it, @[[s historyForSeries:IBSeriesRAM]], @[goodC], 0, 100, 100, 65, 85, YES, IBGraphUnitPercent);
			if (p.showRAMGB) {
				if (ramPercent) append(it, @" ", IBLevelNone);
				append(it, [NSString stringWithFormat:@"%.1f/%.1f GB", s.ramUsed / 1073741824.0, s.ramTotal / 1073741824.0], IBLevelNone);
			}
		}

		if (p.showBattery || p.showChargeGraph) {
			NSString *sym;
			double pct = s.batteryPercent;
			if (s.batteryCharging) sym = @"battery.100.bolt";
			else if (pct >= 88) sym = @"battery.100";
			else if (pct >= 63) sym = @"battery.75";
			else if (pct >= 38) sym = @"battery.50";
			else if (pct >= 13) sym = @"battery.25";
			else sym = @"battery.0";
			IBItem *it = add(@[sym, @"battery.100"], @"BAT");
			it.graphOnly = !p.showBattery;
			append(it, IBPct(pct), IBLevelDescending(pct, 40, 20));
			if (p.showChargeGraph) attachGraph(it, @[[s historyForSeries:IBSeriesCharge]], @[goodC], 0, 100, 100, 20, 40, NO, IBGraphUnitPercent);
			if (list && s.batteryMaxCapacity > 0 && pct >= 0)
				appendSmall(it, [NSString stringWithFormat:@"  ~%.0f mAh", s.batteryMaxCapacity * pct / 100.0]);
		}

		if ((p.showBatteryTemp || p.showTempGraph) && s.batteryTemperature > -100) {
			IBItem *it = add(@[@"thermometer.medium", @"thermometer"], @"TMP");
			it.graphOnly = !p.showBatteryTemp;
			double t = s.batteryTemperature;
			NSString *text = p.useFahrenheit ? [NSString stringWithFormat:@"%.1f°F", t * 9.0 / 5.0 + 32.0] : [NSString stringWithFormat:@"%.1f°C", t];
			append(it, text, IBLevelAscending(t, 36, 42));
			if (p.showTempGraph) attachGraph(it, @[[s historyForSeries:IBSeriesTemp]], @[goodC], NAN, NAN, 4, 36, 42, YES, IBGraphUnitDegrees);
			if (p.showTempGraph && p.useFahrenheit) { it.graphValueScale = 1.8; it.graphValueOffset = 32; }
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

		if ((p.showBatteryCycles || p.showCyclesGraph) && s.batteryCycles >= 0) {
			IBItem *it = add(@[@"arrow.triangle.2.circlepath"], @"CYC");
			it.graphOnly = !p.showBatteryCycles;
			append(it, [NSString stringWithFormat:@"%ld%@", (long)s.batteryCycles, list ? @" cycles" : @""], IBLevelNone);
			if (p.showCyclesGraph) attachGraph(it, @[[s historyForSeries:IBSeriesCycles]], @[goodC], NAN, NAN, 2, 500, 1000, YES, IBGraphUnitNumber);
		}

		if (p.showNetwork || p.showNetworkGraph) {
			IBItem *it = add(@[@"arrow.up.arrow.down"], @"NET");
			it.graphOnly = !p.showNetwork;
			append(it, [NSString stringWithFormat:@"↓%@/s ↑%@/s", IBBytes(s.netDownBytesPerSec, 1), IBBytes(s.netUpBytesPerSec, 1)], IBLevelNone);
			if (p.showNetworkGraph) attachGraph(it, @[[s historyForSeries:IBSeriesNetDown], [s historyForSeries:IBSeriesNetUp]], @[goodC, [UIColor colorWithWhite:1 alpha:0.75]], 0, NAN, 10240, 1048576, 5242880, YES, IBGraphUnitBytesPerSec);
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
	NSMutableArray<IBModule *> *modules = [NSMutableArray array];
	NSMutableString *cfg = [NSMutableString string];
	[cfg appendString:p.collapsed ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowTime ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowCPU ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowRAM ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowBattery ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowTemp ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowNetwork ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowStorage ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowUptime ? @"1" : @"0"];
	[cfg appendString:p.collapsedShowThermal ? @"1" : @"0"];
	[cfg appendString:p.useIcons ? @"1" : @"0"];
	[cfg appendString:p.useFahrenheit ? @"1" : @"0"];
	[cfg appendString:p.showTime ? @"1" : @"0"];
	[cfg appendString:p.showCPU ? @"1" : @"0"];
	[cfg appendString:p.showCPUFreq ? @"1" : @"0"];
	[cfg appendString:p.showCPUInfo ? @"1" : @"0"];
	[cfg appendString:p.showRAMPercent ? @"1" : @"0"];
	[cfg appendString:p.showRAMGB ? @"1" : @"0"];
	[cfg appendString:p.showBattery ? @"1" : @"0"];
	[cfg appendString:p.showBatteryTemp ? @"1" : @"0"];
	[cfg appendString:p.showBatteryPower ? @"1" : @"0"];
	[cfg appendString:p.showBatteryVoltage ? @"1" : @"0"];
	[cfg appendString:p.showCharger ? @"1" : @"0"];
	[cfg appendString:p.showBatteryHealth ? @"1" : @"0"];
	[cfg appendString:p.showBatteryCycles ? @"1" : @"0"];
	[cfg appendString:p.showNetwork ? @"1" : @"0"];
	[cfg appendString:p.showIP ? @"1" : @"0"];
	[cfg appendString:p.showStorage ? @"1" : @"0"];
	[cfg appendString:p.showUptime ? @"1" : @"0"];
	[cfg appendString:p.showThermal ? @"1" : @"0"];
	[cfg appendString:p.showCPUGraph ? @"1" : @"0"];
	[cfg appendString:p.showRAMGraph ? @"1" : @"0"];
	[cfg appendString:p.showChargeGraph ? @"1" : @"0"];
	[cfg appendString:p.showTempGraph ? @"1" : @"0"];
	[cfg appendString:p.showCyclesGraph ? @"1" : @"0"];
	[cfg appendString:p.showNetworkGraph ? @"1" : @"0"];
	[cfg appendFormat:@"%ld%ld", (long)p.layout, (long)p.collapsedMode];

	NSDictionary *labelAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [base colorWithAlphaComponent:0.85]};
	NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
	para.lineBreakMode = NSLineBreakByWordWrapping;

	for (IBItem *item in items) {
		NSMutableAttributedString *line = [NSMutableAttributedString new];
		BOOL textless = item.graphOnly;
		UIImage *icon = (p.useIcons && !textless) ? [self symbolNamed:item.symbols size:p.fontSize * 0.9 color:base] : nil;
		if (icon) {
			NSTextAttachment *att = [NSTextAttachment new];
			att.image = icon;
			// Vertically center the symbol on the cap height
			CGSize size = icon.size;
			att.bounds = CGRectMake(0, round((font.capHeight - size.height) / 2.0), size.width, size.height);
			[line appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
			if (list) {
				[line addAttribute:NSKernAttributeName value:@(1.5) range:NSMakeRange(line.length - 1, 1)];
			} else {
				[line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u00A0" attributes:labelAttrs]];
			}
		} else if (item.label.length > 0 && !textless) {
			if (list) {
				NSMutableAttributedString *lab = [[NSMutableAttributedString alloc] initWithString:item.label attributes:labelAttrs];
				[lab addAttribute:NSKernAttributeName value:@(2.5) range:NSMakeRange(lab.length - 1, 1)];
				[line appendAttributedString:lab];
			} else {
				[line appendAttributedString:[[NSAttributedString alloc] initWithString:[item.label stringByAppendingString:@"\u00A0"] attributes:labelAttrs]];
			}
		}
		// Never wrap inside a module, only between modules
		[item.value.mutableString replaceOccurrencesOfString:@" " withString:@"\u00A0" options:0 range:NSMakeRange(0, item.value.length)];
		if (!textless) [line appendAttributedString:item.value];
		if (line.length > 0) [line addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, line.length)];

		IBModule *m = [IBModule new];
		m.identifier = item.label ?: @"";
		m.configKey = cfg;
		m.text = line;
		m.graphSeries = item.graphSeries ?: @[];
		m.graphColors = item.graphColors ?: @[];
		m.graphBandColors = item.graphBandColors ?: @[];
		m.graphThresholds = item.graphThresholds ?: @[];
		m.graphThresholdColors = item.graphThresholdColors ?: @[];
		m.graphUnit = item.graphUnit;
		m.graphValueScale = item.graphValueScale != 0 ? item.graphValueScale : 1;
		m.graphValueOffset = item.graphValueOffset;
		m.graphMin = item.graphSeries ? item.graphMin : NAN;
		m.graphMax = item.graphSeries ? item.graphMax : NAN;
		m.graphMinSpan = item.graphMinSpan;
		[modules addObject:m];
	}

	if (modules.count == 0) {
		IBModule *m = [IBModule new];
		m.identifier = @"InfoBar";
		m.configKey = cfg;
		m.text = [[NSAttributedString alloc] initWithString:@"InfoBar" attributes:labelAttrs];
		m.graphSeries = @[];
		m.graphColors = @[];
		m.graphBandColors = @[];
		m.graphThresholds = @[];
		m.graphThresholdColors = @[];
		m.graphMin = NAN;
		m.graphMax = NAN;
		[modules addObject:m];
	}
	return modules;
}

@end
