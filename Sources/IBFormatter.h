#import <UIKit/UIKit.h>

@class IBStats, IBPrefs;

NS_ASSUME_NONNULL_BEGIN

// Builds the bar's text from the current measurements.
@interface IBFormatter : NSObject
+ (NSAttributedString *)textForStats:(IBStats *)stats prefs:(IBPrefs *)prefs;
@end

NS_ASSUME_NONNULL_END
