#import <UIKit/UIKit.h>

@class IBStats, IBPrefs;

NS_ASSUME_NONNULL_BEGIN

@interface IBModule : NSObject
@property (nonatomic, copy) NSAttributedString *text;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *graphSeries;
@property (nonatomic, copy) NSArray<UIColor *> *graphColors;
@property (nonatomic) double graphMin;
@property (nonatomic) double graphMax;
@property (nonatomic) double graphMinSpan;
@end

// Builds the bar's modules from the current measurements.
@interface IBFormatter : NSObject
+ (NSArray<IBModule *> *)modulesForStats:(IBStats *)stats prefs:(IBPrefs *)prefs;
@end

NS_ASSUME_NONNULL_END
