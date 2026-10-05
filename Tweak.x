#import <UIKit/UIKit.h>
#import "IBController.h"

@interface SpringBoard : UIApplication
@end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	// Wait briefly until SpringBoard's scenes are connected
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[[IBController sharedInstance] start];
	});
}

%end
