#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Full-screen window above everything else that passes touches outside the
// bar through to whatever is underneath.
@interface IBOverlayWindow : UIWindow
@end

// Root view controller that reports size changes (rotation).
@interface IBOverlayViewController : UIViewController
@property (nonatomic, copy, nullable) void (^layoutHandler)(void);
@end

NS_ASSUME_NONNULL_END
