#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Owns the overlay window, bar, timer and preferences inside SpringBoard.
@interface IBController : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

NS_ASSUME_NONNULL_END
