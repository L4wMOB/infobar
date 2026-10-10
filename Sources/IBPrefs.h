#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define IB_PREFS_DOMAIN @"com.mathelord.infobar"
#define IB_NOTIFY_PREFS "com.mathelord.infobar/prefschanged"
#define IB_NOTIFY_RESET "com.mathelord.infobar/resetposition"

typedef NS_ENUM(NSInteger, IBLayout) {
	IBLayoutRow = 0,  // everything in one row
	IBLayoutList = 1, // one value per line
};

typedef NS_ENUM(NSInteger, IBCollapsedMode) {
	IBCollapsedModeSummary = 0, // CPU, RAM, battery in %
	IBCollapsedModeButtons = 1, // buttons only
};

// Immutable snapshot of the preferences; safe to pass between threads.
@interface IBPrefs : NSObject

+ (instancetype)load;

// General
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL pinned;
@property (nonatomic, readonly) BOOL showPinButton;
@property (nonatomic, readonly) BOOL showOnLockScreen;
@property (nonatomic, readonly) BOOL hideInLandscape;
@property (nonatomic, readonly) BOOL doubleTapTogglesLayout;
@property (nonatomic, readonly) BOOL clickThrough;
@property (nonatomic, readonly) BOOL collapsed;
@property (nonatomic, readonly) BOOL showCollapseButton;
@property (nonatomic, readonly) IBCollapsedMode collapsedMode;
@property (nonatomic, readonly) BOOL collapsedShowTime;
@property (nonatomic, readonly) BOOL collapsedShowCPU;
@property (nonatomic, readonly) BOOL collapsedShowRAM;
@property (nonatomic, readonly) BOOL collapsedShowBattery;
@property (nonatomic, readonly) BOOL collapsedShowTemp;
@property (nonatomic, readonly) BOOL collapsedShowNetwork;
@property (nonatomic, readonly) BOOL collapsedShowStorage;
@property (nonatomic, readonly) BOOL collapsedShowUptime;
@property (nonatomic, readonly) BOOL collapsedShowThermal;
@property (nonatomic, readonly) double updateInterval;
@property (nonatomic, readonly) CGPoint position;

// Appearance
@property (nonatomic, readonly) IBLayout layout;
@property (nonatomic, readonly) BOOL useIcons;
@property (nonatomic, readonly) BOOL colorizeValues;
@property (nonatomic, readonly) BOOL useBlur;
@property (nonatomic, readonly) double fontSize;
@property (nonatomic, readonly) double backgroundAlpha;
@property (nonatomic, readonly) double cornerRadius;
@property (nonatomic, readonly, strong) UIColor *textColor;
@property (nonatomic, readonly) BOOL useFahrenheit;
@property (nonatomic, readonly) double bgExtendTop;
@property (nonatomic, readonly) double bgExtendBottom;
@property (nonatomic, readonly) double graphHeight;
@property (nonatomic, readonly) double graphWidth;
@property (nonatomic, readonly) double shadowStrength;

// Modules
@property (nonatomic, readonly) BOOL showTime;
@property (nonatomic, readonly) BOOL showCPU;
@property (nonatomic, readonly) BOOL showCPUFreq;
@property (nonatomic, readonly) BOOL showCPUInfo;
@property (nonatomic, readonly) BOOL showRAMPercent;
@property (nonatomic, readonly) BOOL showRAMGB;
@property (nonatomic, readonly) BOOL showBattery;
@property (nonatomic, readonly) BOOL showBatteryTemp;
@property (nonatomic, readonly) BOOL showBatteryPower;
@property (nonatomic, readonly) BOOL showBatteryVoltage;
@property (nonatomic, readonly) BOOL showCharger;
@property (nonatomic, readonly) BOOL showBatteryHealth;
@property (nonatomic, readonly) BOOL showBatteryCycles;
@property (nonatomic, readonly) BOOL showNetwork;
@property (nonatomic, readonly) BOOL showIP;
@property (nonatomic, readonly) BOOL showStorage;
@property (nonatomic, readonly) BOOL showUptime;
@property (nonatomic, readonly) BOOL showThermal;

// Realtime graphs
@property (nonatomic, readonly) BOOL showCPUGraph;
@property (nonatomic, readonly) BOOL showRAMGraph;
@property (nonatomic, readonly) BOOL showChargeGraph;
@property (nonatomic, readonly) BOOL showTempGraph;
@property (nonatomic, readonly) BOOL showCyclesGraph;
@property (nonatomic, readonly) BOOL showNetworkGraph;

// Writes from the overlay (pin, position, layout)
+ (void)setValue:(nullable id)value forKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
