#import "IBStats.h"
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/socket.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <dlfcn.h>

// <net/route.h> is missing from the iOS SDK
#ifndef NET_RT_IFLIST2
#define NET_RT_IFLIST2 6
#endif
#ifndef RTM_IFINFO2
#define RTM_IFINFO2 0x12
#endif

#pragma mark - IOReport (private, per dlopen)

typedef struct __IOReportSubscriptionCF *IOReportSubscriptionRef;

static CFDictionaryRef (*pIOReportCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
static IOReportSubscriptionRef (*pIOReportCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
static CFDictionaryRef (*pIOReportCreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static CFDictionaryRef (*pIOReportCreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
static int32_t (*pIOReportStateGetCount)(CFDictionaryRef);
static CFStringRef (*pIOReportStateGetNameForIndex)(CFDictionaryRef, int32_t);
static int64_t (*pIOReportStateGetResidency)(CFDictionaryRef, int32_t);
static CFStringRef (*pIOReportChannelGetChannelName)(CFDictionaryRef);

static BOOL IBLoadIOReport(void) {
	static BOOL loaded = NO;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
		if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_NOW);
		if (!h) return;
		pIOReportCopyChannelsInGroup = dlsym(h, "IOReportCopyChannelsInGroup");
		pIOReportCreateSubscription = dlsym(h, "IOReportCreateSubscription");
		pIOReportCreateSamples = dlsym(h, "IOReportCreateSamples");
		pIOReportCreateSamplesDelta = dlsym(h, "IOReportCreateSamplesDelta");
		pIOReportStateGetCount = dlsym(h, "IOReportStateGetCount");
		pIOReportStateGetNameForIndex = dlsym(h, "IOReportStateGetNameForIndex");
		pIOReportStateGetResidency = dlsym(h, "IOReportStateGetResidency");
		pIOReportChannelGetChannelName = dlsym(h, "IOReportChannelGetChannelName");
		loaded = pIOReportCopyChannelsInGroup && pIOReportCreateSubscription && pIOReportCreateSamples &&
			pIOReportCreateSamplesDelta && pIOReportStateGetCount && pIOReportStateGetNameForIndex &&
			pIOReportStateGetResidency && pIOReportChannelGetChannelName;
	});
	return loaded;
}

#pragma mark - Hilfsfunktionen

static int64_t IBNumber(CFDictionaryRef dict, CFStringRef key, int64_t fallback) {
	if (!dict) return fallback;
	CFTypeRef v = CFDictionaryGetValue(dict, key);
	if (!v) return fallback;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int64_t n = 0;
		CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
		return n;
	}
	if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
	return fallback;
}

// Some battery values (amperage) are reported as unsigned 32/64-bit numbers.
static int64_t IBSigned(int64_t v) {
	if (v > 0x7FFFFFFFLL && v <= 0xFFFFFFFFLL) v -= 0x100000000LL;
	return v;
}

static NSString *IBSysctlString(const char *name) {
	size_t len = 0;
	if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return nil;
	char *buf = malloc(len);
	if (!buf) return nil;
	NSString *s = nil;
	if (sysctlbyname(name, buf, &len, NULL, 0) == 0) s = [NSString stringWithUTF8String:buf];
	free(buf);
	return s;
}

static int IBSysctlInt(const char *name, int fallback) {
	int v = 0;
	size_t len = sizeof(v);
	if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return fallback;
	return v;
}

// Chip name + max clock (MHz) as a fallback when the DVFS table can't be read.
static void IBChipInfo(NSString *machine, NSString **name, double *maxMHz) {
	struct { const char *prefix; const char *chip; double mhz; } table[] = {
		{"iPhone11,", "A12 Bionic", 2490},
		{"iPhone12,", "A13 Bionic", 2650},
		{"iPhone13,", "A14 Bionic", 2990},
		{"iPhone14,", "A15 Bionic", 3230},
		{"iPhone15,", "A16 Bionic", 3460},
		{"iPhone16,", "A17 Pro", 3780},
		{"iPhone17,1", "A18 Pro", 4050},
		{"iPhone17,2", "A18 Pro", 4050},
		{"iPhone17,", "A18", 4040},
		{"iPhone18,", "A19", 4260},
	};
	for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
		if ([machine hasPrefix:@(table[i].prefix)]) {
			*name = @(table[i].chip);
			*maxMHz = table[i].mhz;
			return;
		}
	}
	*name = machine ?: @"CPU";
	*maxMHz = -1;
}

// Reads a DVFS table (pairs of uint32 frequency, uint32 voltage) from the pmgr node.
static NSArray<NSNumber *> *IBReadDVFSTable(io_registry_entry_t pmgr, NSArray<NSString *> *keys) {
	for (NSString *key in keys) {
		CFTypeRef prop = IORegistryEntryCreateCFProperty(pmgr, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
		if (!prop) continue;
		NSMutableArray *freqs = [NSMutableArray array];
		if (CFGetTypeID(prop) == CFDataGetTypeID()) {
			CFDataRef data = prop;
			const uint8_t *bytes = CFDataGetBytePtr(data);
			CFIndex len = CFDataGetLength(data);
			for (CFIndex off = 0; off + 8 <= len; off += 8) {
				uint32_t raw;
				memcpy(&raw, bytes + off, sizeof(raw));
				double mhz;
				if (raw >= 100000000u) mhz = raw / 1e6;       // Hz
				else if (raw >= 100000u) mhz = raw / 1e3;     // kHz
				else mhz = raw;                               // MHz
				if (mhz >= 100 && mhz <= 6000) [freqs addObject:@(mhz)];
			}
		}
		CFRelease(prop);
		if (freqs.count > 0) return freqs;
	}
	return nil;
}

// Fallback: roughly measure the clock with a chain of dependent additions
// (each addition takes exactly one cycle). Takes about 1-2 ms.
static double IBEstimateCurrentCoreMHz(void) {
#if defined(__arm64__) || defined(__aarch64__)
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) mach_timebase_info(&tb);
	double best = 0;
	for (int run = 0; run < 3; run++) {
		uint64_t n = 100000, x = 0;
		uint64_t start = mach_absolute_time();
		__asm__ volatile(
			"1:\n"
			"add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n"
			"add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n"
			"add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n"
			"add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n" "add %[x], %[x], #1\n"
			"subs %[n], %[n], #1\n"
			"b.ne 1b\n"
			: [x] "+r"(x), [n] "+r"(n) : : "cc");
		uint64_t elapsed = mach_absolute_time() - start;
		double ns = (double)elapsed * tb.numer / tb.denom;
		if (ns > 0) {
			double mhz = (16.0 * 100000.0) / ns * 1000.0;
			if (mhz > best) best = mhz;
		}
	}
	return best;
#else
	return -1;
#endif
}

#pragma mark - IBStats

@implementation IBStats {
	// CPU ticks
	uint64_t *_prevTicks;
	natural_t _prevCPUCount;
	// IOReport
	IOReportSubscriptionRef _subscription;
	CFMutableDictionaryRef _subscribedChannels;
	CFDictionaryRef _prevSample;
	BOOL _ioReportFailed;
	BOOL _ioReportChannelsSeen;
	int _samplesWithoutChannels;
	NSArray<NSNumber *> *_eTable;
	NSArray<NSNumber *> *_pTable;
	double _fallbackMaxMHz;
	// Battery
	io_service_t _battery;
	// Network
	uint64_t _prevIn, _prevOut;
	uint64_t _prevNetTime;
	// Storage (refreshed rarely)
	uint64_t _lastStorageTime;
	uint64_t _lastIPTime;
	// Graph history
	NSMutableArray<NSMutableArray<NSNumber *> *> *_history;
	uint64_t _lastHistoryTime;
}

+ (instancetype)sharedInstance {
	static IBStats *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [[self alloc] init]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_cpuUsage = -1;
		_cpuFreqPMHz = -1;
		_cpuFreqEMHz = -1;
		_cpuFreqMaxMHz = -1;
		_batteryPercent = -1;
		_batteryTemperature = -1000; // can legitimately be negative, hence a dedicated sentinel
		_batteryVoltage = -1;
		_batteryHealth = -1;
		_batteryCycles = -1;
		_netDownBytesPerSec = -1;
		_netUpBytesPerSec = -1;

		_measureCPU = _measureMemory = _measureBattery = _measureNetwork = _measureSystem = YES;
		_history = [NSMutableArray array];
		for (NSInteger i = 0; i < IBSeriesCount; i++) [_history addObject:[NSMutableArray arrayWithCapacity:IB_HISTORY_COUNT + 1]];

		_cpuCoreCount = [NSProcessInfo processInfo].activeProcessorCount;
		if (IBSysctlInt("hw.nperflevels", 0) >= 2) {
			_cpuPerformanceCores = IBSysctlInt("hw.perflevel0.logicalcpu", 0);
			_cpuEfficiencyCores = IBSysctlInt("hw.perflevel1.logicalcpu", 0);
		}
		NSString *machine = IBSysctlString("hw.machine");
		NSString *chip = nil;
		double maxMHz = -1;
		IBChipInfo(machine, &chip, &maxMHz);
		_chipName = [chip copy];
		_fallbackMaxMHz = maxMHz;
		_ramTotal = [NSProcessInfo processInfo].physicalMemory;

		io_registry_entry_t pmgr = IORegistryEntryFromPath(MACH_PORT_NULL, "IODeviceTree:/arm-io/pmgr");
		if (pmgr) {
			_eTable = IBReadDVFSTable(pmgr, @[@"voltage-states1-sram", @"voltage-states1"]);
			_pTable = IBReadDVFSTable(pmgr, @[@"voltage-states5-sram", @"voltage-states5"]);
			IOObjectRelease(pmgr);
		}
		NSNumber *tableMax = [(_pTable ?: _eTable) valueForKeyPath:@"@max.doubleValue"];
		_cpuFreqMaxMHz = tableMax ? tableMax.doubleValue : _fallbackMaxMHz;
	}
	return self;
}

- (void)refresh {
	@autoreleasepool {
		if (_measureCPU) [self refreshCPUUsage];
		if (self.measureCPUFrequency) [self refreshCPUFrequency];
		if (_measureMemory) [self refreshMemory];
		if (_measureBattery) [self refreshBattery];
		if (_measureNetwork) [self refreshNetwork];
		else _prevNetTime = 0; // the speed is measured from scratch when it is switched on again
		if (_measureSystem) [self refreshSystem];
		[self recordHistory];
	}
}

#pragma mark History

- (void)recordHistory {
	uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
	// Extra refreshes (settings changed, collapse, ...) must not add uneven samples
	if (_lastHistoryTime > 0 && now - _lastHistoryTime < 300 * NSEC_PER_MSEC) return;
	_lastHistoryTime = now;

	void (^push)(IBSeries, double) = ^(IBSeries series, double v) {
		NSMutableArray<NSNumber *> *a = self->_history[series];
		[a addObject:@(v)];
		if (a.count > IB_HISTORY_COUNT) [a removeObjectsInRange:NSMakeRange(0, a.count - IB_HISTORY_COUNT)];
	};
	// Only what was measured this time (no stale values)
	if (_measureCPU && _cpuUsage >= 0) push(IBSeriesCPU, _cpuUsage);
	if (_measureMemory && _ramUsagePercent >= 0) push(IBSeriesRAM, _ramUsagePercent);
	if (_measureBattery && _batteryPercent >= 0) push(IBSeriesCharge, _batteryPercent);
	if (_measureBattery && _batteryTemperature > -100) push(IBSeriesTemp, _batteryTemperature);
	if (_measureBattery && _batteryCycles >= 0) push(IBSeriesCycles, (double)_batteryCycles);
	if (_measureNetwork && _netDownBytesPerSec >= 0 && _netUpBytesPerSec >= 0) {
		push(IBSeriesNetDown, _netDownBytesPerSec);
		push(IBSeriesNetUp, _netUpBytesPerSec);
	}
}

- (NSArray<NSNumber *> *)historyForSeries:(IBSeries)series {
	if (series < 0 || series >= IBSeriesCount) return @[];
	return [_history[series] copy];
}

#pragma mark CPU

- (void)refreshCPUUsage {
	natural_t count = 0;
	processor_info_array_t info = NULL;
	mach_msg_type_number_t infoCount = 0;
	if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) != KERN_SUCCESS) return;

	uint64_t *ticks = calloc(count * CPU_STATE_MAX, sizeof(uint64_t));
	for (natural_t i = 0; i < count; i++)
		for (int s = 0; s < CPU_STATE_MAX; s++)
			ticks[i * CPU_STATE_MAX + s] = (uint32_t)info[i * CPU_STATE_MAX + s];
	vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));

	if (_prevTicks && _prevCPUCount == count) {
		uint64_t busy = 0, total = 0;
		for (natural_t i = 0; i < count; i++) {
			for (int s = 0; s < CPU_STATE_MAX; s++) {
				// Ticks are 32 bit and can wrap around
				uint32_t d = (uint32_t)(ticks[i * CPU_STATE_MAX + s] - _prevTicks[i * CPU_STATE_MAX + s]);
				total += d;
				if (s != CPU_STATE_IDLE) busy += d;
			}
		}
		if (total > 0) _cpuUsage = (double)busy * 100.0 / (double)total;
	}
	free(_prevTicks);
	_prevTicks = ticks;
	_prevCPUCount = count;
}

- (BOOL)setUpIOReport {
	if (_ioReportFailed) return NO;
	if (_subscription) return YES;
	if (!IBLoadIOReport()) return NO;
	CFDictionaryRef channels = pIOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
	if (!channels) {
		_ioReportFailed = YES;
		return NO;
	}
	CFMutableDictionaryRef mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(channels), channels);
	CFRelease(channels);
	CFMutableDictionaryRef subscribed = NULL;
	_subscription = pIOReportCreateSubscription(NULL, mutableChannels, &subscribed, 0, NULL);
	CFRelease(mutableChannels);
	if (!_subscription || !subscribed) {
		_ioReportFailed = YES;
		return NO;
	}
	_subscribedChannels = subscribed;
	return YES;
}

static double IBClusterFrequency(CFDictionaryRef channel, NSArray<NSNumber *> *table, double *activeOut) {
	int32_t count = pIOReportStateGetCount(channel);
	double weighted = 0, active = 0, all = 0;
	NSInteger tableIndex = 0;
	for (int32_t i = 0; i < count; i++) {
		int64_t res = pIOReportStateGetResidency(channel, i);
		if (res < 0) res = 0;
		all += res;
		NSString *name = (__bridge NSString *)pIOReportStateGetNameForIndex(channel, i);
		if ([name isEqualToString:@"IDLE"] || [name isEqualToString:@"OFF"] || [name isEqualToString:@"DOWN"]) continue;
		if (tableIndex < (NSInteger)table.count) {
			weighted += res * table[tableIndex].doubleValue;
			active += res;
		}
		tableIndex++;
	}
	if (activeOut) *activeOut = all > 0 ? active / all : 0;
	return active > 0 ? weighted / active : -1;
}

- (void)refreshCPUFrequency {
	if ((_eTable || _pTable) && [self setUpIOReport]) {
		CFDictionaryRef sample = pIOReportCreateSamples(_subscription, _subscribedChannels, NULL);
		if (!sample) return;
		if (_prevSample) {
			CFDictionaryRef delta = pIOReportCreateSamplesDelta(_prevSample, sample, NULL);
			if (delta) {
				CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
				double pSum = 0, pWeight = 0, eSum = 0, eWeight = 0;
				BOOL foundChannel = NO;
				if (items && CFGetTypeID(items) == CFArrayGetTypeID()) {
					for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
						CFDictionaryRef ch = CFArrayGetValueAtIndex(items, i);
						NSString *name = (__bridge NSString *)pIOReportChannelGetChannelName(ch);
						BOOL isP = [name hasPrefix:@"PCPU"];
						BOOL isE = [name hasPrefix:@"ECPU"];
						if (!isP && !isE) continue;
						if (!(isP ? _pTable : _eTable)) continue;
						foundChannel = YES;
						double activeRatio = 0;
						double f = IBClusterFrequency(ch, isP ? _pTable : _eTable, &activeRatio);
						if (f <= 0) continue;
						// Weight multiple clusters by their active time
						double w = MAX(activeRatio, 1e-6);
						if (isP) { pSum += f * w; pWeight += w; }
						else { eSum += f * w; eWeight += w; }
					}
				}
				if (foundChannel) {
					// Cluster fully idle -> show the lowest state
					_cpuFreqPMHz = pWeight > 0 ? pSum / pWeight : (_pTable ? _pTable.firstObject.doubleValue : -1);
					_cpuFreqEMHz = eWeight > 0 ? eSum / eWeight : (_eTable ? _eTable.firstObject.doubleValue : -1);
					_cpuFreqEstimated = NO;
				}
				CFRelease(delta);
			}
			CFRelease(_prevSample);
		}
		_prevSample = sample;
		if (_ioReportChannelsSeen || _samplesWithoutChannels++ < 3) return;
		// Unknown channel names on this device: permanently switch to estimation
		_ioReportFailed = YES;
	}

	// No IOReport / no DVFS table: estimate the clock
	__block double mhz = -1;
	dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
	dispatch_sync(q, ^{ mhz = IBEstimateCurrentCoreMHz(); });
	if (_fallbackMaxMHz > 0 && mhz > _fallbackMaxMHz * 1.05) mhz = _fallbackMaxMHz;
	_cpuFreqPMHz = mhz;
	_cpuFreqEMHz = -1;
	_cpuFreqEstimated = YES;
}

#pragma mark RAM

- (void)refreshMemory {
	vm_statistics64_data_t vm;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return;
	uint64_t page = vm_kernel_page_size;
	// like Activity Monitor: app memory + wired + compressed
	uint64_t appPages = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
	uint64_t used = (appPages + vm.wire_count + vm.compressor_page_count) * page;
	if (used > _ramTotal) used = _ramTotal;
	_ramUsed = used;
	_ramUsagePercent = _ramTotal > 0 ? (double)used * 100.0 / (double)_ramTotal : -1;
}

#pragma mark Battery

- (void)refreshBattery {
	if (!_battery) _battery = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSmartBattery"));
	CFMutableDictionaryRef props = NULL;
	if (_battery && IORegistryEntryCreateCFProperties(_battery, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
		int64_t current = IBNumber(props, CFSTR("CurrentCapacity"), -1);
		int64_t max = IBNumber(props, CFSTR("MaxCapacity"), 100);
		if (current >= 0 && max > 0 && max <= 100) _batteryPercent = (double)current * 100.0 / (double)max;

		_batteryCharging = IBNumber(props, CFSTR("IsCharging"), 0) != 0;
		_batteryExternalPower = IBNumber(props, CFSTR("ExternalConnected"), 0) != 0;
		_batteryFullyCharged = IBNumber(props, CFSTR("FullyCharged"), 0) != 0;

		int64_t temp = IBNumber(props, CFSTR("Temperature"), INT64_MIN);
		if (temp != INT64_MIN) _batteryTemperature = temp / 100.0;

		int64_t mv = IBNumber(props, CFSTR("Voltage"), -1);
		_batteryVoltage = mv > 0 ? mv / 1000.0 : -1;

		int64_t ma = IBNumber(props, CFSTR("InstantAmperage"), INT64_MIN);
		if (ma == INT64_MIN) ma = IBNumber(props, CFSTR("Amperage"), 0);
		ma = IBSigned(ma);
		_batteryAmperage = (double)ma;
		_batteryPower = _batteryVoltage > 0 ? _batteryVoltage * (double)ma / 1000.0 : 0;

		_batteryCycles = (NSInteger)IBNumber(props, CFSTR("CycleCount"), -1);

		int64_t design = IBNumber(props, CFSTR("DesignCapacity"), -1);
		if (design <= 0) {
			CFDictionaryRef batteryData = CFDictionaryGetValue(props, CFSTR("BatteryData"));
			if (batteryData && CFGetTypeID(batteryData) == CFDictionaryGetTypeID())
				design = IBNumber(batteryData, CFSTR("DesignCapacity"), -1);
		}
		int64_t nominal = IBNumber(props, CFSTR("NominalChargeCapacity"), -1);
		if (nominal <= 0) nominal = IBNumber(props, CFSTR("AppleRawMaxCapacity"), -1);
		_batteryDesignCapacity = (NSInteger)design;
		_batteryMaxCapacity = (NSInteger)nominal;
		_batteryHealth = (design > 0 && nominal > 0) ? MIN(100.0, (double)nominal * 100.0 / (double)design) : -1;

		_chargerWatts = 0;
		CFDictionaryRef adapter = CFDictionaryGetValue(props, CFSTR("AdapterDetails"));
		if (adapter && CFGetTypeID(adapter) == CFDictionaryGetTypeID())
			_chargerWatts = (NSInteger)MAX(0, IBNumber(adapter, CFSTR("Watts"), 0));

		CFRelease(props);
	}

	if (_batteryPercent < 0) {
		__block float level = -1;
		__block UIDeviceBatteryState state = UIDeviceBatteryStateUnknown;
		void (^read)(void) = ^{
			UIDevice *device = [UIDevice currentDevice];
			device.batteryMonitoringEnabled = YES;
			level = device.batteryLevel;
			state = device.batteryState;
		};
		if ([NSThread isMainThread]) read();
		else dispatch_sync(dispatch_get_main_queue(), read);
		if (level >= 0) _batteryPercent = level * 100.0;
		_batteryCharging = state == UIDeviceBatteryStateCharging;
		_batteryExternalPower = state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
	}
}

#pragma mark Network

static BOOL IBCountInterface(const char *name, size_t len) {
	// Wi-Fi (en*) and cellular (pdp_ip*); don't double count VPN, AWDL, loopback etc.
	if (len >= 2 && strncmp(name, "en", 2) == 0) return YES;
	if (len >= 6 && strncmp(name, "pdp_ip", 6) == 0) return YES;
	return NO;
}

- (void)refreshNetwork {
	int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
	size_t len = 0;
	if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0 || len == 0) return;
	char *buf = malloc(len);
	if (!buf) return;
	if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) {
		free(buf);
		return;
	}
	uint64_t inBytes = 0, outBytes = 0;
	for (char *next = buf; next < buf + len;) {
		struct if_msghdr *ifm = (struct if_msghdr *)next;
		if (ifm->ifm_msglen == 0) break;
		if (ifm->ifm_type == RTM_IFINFO2) {
			struct if_msghdr2 *if2m = (struct if_msghdr2 *)ifm;
			struct sockaddr_dl *sdl = (struct sockaddr_dl *)(if2m + 1);
			if (IBCountInterface(sdl->sdl_data, sdl->sdl_nlen)) {
				inBytes += if2m->ifm_data.ifi_ibytes;
				outBytes += if2m->ifm_data.ifi_obytes;
			}
		}
		next += ifm->ifm_msglen;
	}
	free(buf);

	uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
	if (_prevNetTime > 0 && now > _prevNetTime) {
		double secs = (now - _prevNetTime) / 1e9;
		// Counters can reset when interfaces change
		_netDownBytesPerSec = inBytes >= _prevIn ? (inBytes - _prevIn) / secs : 0;
		_netUpBytesPerSec = outBytes >= _prevOut ? (outBytes - _prevOut) / secs : 0;
	}
	_prevIn = inBytes;
	_prevOut = outBytes;
	_prevNetTime = now;
}

#pragma mark System

- (void)refreshSystem {
	uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

	if (_lastStorageTime == 0 || now - _lastStorageTime > 30ull * NSEC_PER_SEC) {
		struct statfs fs;
		if (statfs("/private/var", &fs) == 0) {
			_storageFree = (uint64_t)fs.f_bavail * fs.f_bsize;
			_storageTotal = (uint64_t)fs.f_blocks * fs.f_bsize;
		}
		_lastStorageTime = now;
	}

	if (_lastIPTime == 0 || now - _lastIPTime > 5ull * NSEC_PER_SEC) {
		NSString *ip = nil;
		struct ifaddrs *addrs = NULL;
		if (getifaddrs(&addrs) == 0) {
			for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
				if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
				if (strcmp(a->ifa_name, "en0") != 0) continue;
				char str[INET_ADDRSTRLEN];
				if (inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, str, sizeof(str))) {
					ip = @(str);
					break;
				}
			}
			freeifaddrs(addrs);
		}
		_wifiIPAddress = [ip copy];
		_lastIPTime = now;
	}

	struct timeval boot;
	size_t len = sizeof(boot);
	int mib[2] = {CTL_KERN, KERN_BOOTTIME};
	if (sysctl(mib, 2, &boot, &len, NULL, 0) == 0 && boot.tv_sec > 0)
		_uptime = [[NSDate date] timeIntervalSince1970] - boot.tv_sec;

	_thermalState = [NSProcessInfo processInfo].thermalState;
}

@end
