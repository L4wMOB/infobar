#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Number of samples kept per graph (one sample per update interval)
#define IB_HISTORY_COUNT 60

typedef NS_ENUM(NSInteger, IBSeries) {
	IBSeriesCPU,
	IBSeriesRAM,
	IBSeriesCharge,
	IBSeriesTemp,
	IBSeriesCycles,
	IBSeriesNetDown,
	IBSeriesNetUp,
	IBSeriesCount,
};

// Collects all system values. -refresh must be called periodically (off the main
// thread); rates (CPU, network) are computed from the delta to the previous
// call. Unknown values are negative.
@interface IBStats : NSObject

+ (instancetype)sharedInstance;
- (void)refresh;

// Recent samples (oldest first) for the graphs. Call on the same queue as -refresh.
- (NSArray<NSNumber *> *)historyForSeries:(IBSeries)series;

// Only measure the clock when it's shown (estimation costs some CPU time)
@property (nonatomic) BOOL measureCPUFrequency;

// CPU
@property (nonatomic, readonly) double cpuUsage;              // 0..100
@property (nonatomic, readonly) NSInteger cpuCoreCount;
@property (nonatomic, readonly) NSInteger cpuPerformanceCores; // 0 = unknown
@property (nonatomic, readonly) NSInteger cpuEfficiencyCores;
@property (nonatomic, readonly) double cpuFreqPMHz;           // average clock of P cores
@property (nonatomic, readonly) double cpuFreqEMHz;           // average clock of E cores
@property (nonatomic, readonly) double cpuFreqMaxMHz;         // highest clock per DVFS table
@property (nonatomic, readonly) BOOL cpuFreqEstimated;        // YES = estimated with a timing loop
@property (nonatomic, readonly, copy) NSString *chipName;

// RAM
@property (nonatomic, readonly) uint64_t ramTotal;
@property (nonatomic, readonly) uint64_t ramUsed;
@property (nonatomic, readonly) double ramUsagePercent;

// Battery
@property (nonatomic, readonly) double batteryPercent;
@property (nonatomic, readonly) BOOL batteryCharging;
@property (nonatomic, readonly) BOOL batteryExternalPower;
@property (nonatomic, readonly) BOOL batteryFullyCharged;
@property (nonatomic, readonly) double batteryTemperature;    // °C, < -100 = unknown
@property (nonatomic, readonly) double batteryVoltage;        // V
@property (nonatomic, readonly) double batteryAmperage;       // mA (negative = discharging)
@property (nonatomic, readonly) double batteryPower;          // W  (negative = discharging)
@property (nonatomic, readonly) double batteryHealth;         // %
@property (nonatomic, readonly) NSInteger batteryCycles;
@property (nonatomic, readonly) NSInteger batteryDesignCapacity; // mAh
@property (nonatomic, readonly) NSInteger batteryMaxCapacity;    // mAh
@property (nonatomic, readonly) NSInteger chargerWatts;

// Network
@property (nonatomic, readonly) double netDownBytesPerSec;
@property (nonatomic, readonly) double netUpBytesPerSec;
@property (nonatomic, readonly, copy, nullable) NSString *wifiIPAddress;

// Storage / system
@property (nonatomic, readonly) uint64_t storageFree;
@property (nonatomic, readonly) uint64_t storageTotal;
@property (nonatomic, readonly) NSTimeInterval uptime;
@property (nonatomic, readonly) NSProcessInfoThermalState thermalState;

@end

NS_ASSUME_NONNULL_END
