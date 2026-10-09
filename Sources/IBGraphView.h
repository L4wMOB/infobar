#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IBGraphView : UIView
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *series;
@property (nonatomic, copy) NSArray<UIColor *> *colors;
@property (nonatomic, copy) NSArray<UIColor *> *bandColors;
@property (nonatomic, copy) NSArray<NSNumber *> *bandThresholds;
@property (nonatomic, copy) NSArray<UIColor *> *thresholdColors;
// Fixed bounds of the value range; NAN = automatic
@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;
// Smallest range shown so tiny fluctuations don't fill the whole graph
@property (nonatomic) double minSpan;
@end

NS_ASSUME_NONNULL_END
