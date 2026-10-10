#import "IBOverlayWindow.h"

@implementation IBOverlayWindow {
	NSTimeInterval _lastTapTime;
	CGPoint _lastTapPoint;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *view = [super hitTest:point withEvent:event];
	if (view == self || view == self.rootViewController.view) return nil;
	if (!self.touchThrough) return view;

	for (UIView *v = view; v; v = v.superview) {
		if ([v isKindOfClass:[UIControl class]]) return view;
	}
	if (event == nil || event.type == UIEventTypeTouches) [self registerTapAtPoint:point time:event ? event.timestamp : [NSProcessInfo processInfo].systemUptime];
	return nil;
}

- (void)registerTapAtPoint:(CGPoint)point time:(NSTimeInterval)time {
	NSTimeInterval dt = time - _lastTapTime;
	if (_lastTapTime > 0 && dt >= 0 && dt < 0.05) return; // the same touch hit-tested again
	CGFloat dist = hypot(point.x - _lastTapPoint.x, point.y - _lastTapPoint.y);
	if (_lastTapTime > 0 && dt < 0.35 && dist < 60) {
		_lastTapTime = 0;
		void (^handler)(void) = self.doubleTapHandler;
		if (handler) dispatch_async(dispatch_get_main_queue(), handler);
	} else {
		_lastTapTime = time;
		_lastTapPoint = point;
	}
}

// Private UIKit overrides: show on the lock screen too, never become key window
// and don't affect the status bar.
+ (BOOL)_isSecure {
	return YES;
}

- (BOOL)_isSecure {
	return YES;
}

- (BOOL)_shouldCreateContextAsSecure {
	return YES;
}

- (BOOL)_canBecomeKeyWindow {
	return NO;
}

- (BOOL)canBecomeKeyWindow {
	return NO;
}

- (BOOL)_canAffectStatusBarAppearance {
	return NO;
}

@end

@implementation IBOverlayViewController

- (void)loadView {
	UIView *view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
	view.backgroundColor = [UIColor clearColor];
	view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.view = view;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	if (self.layoutHandler) self.layoutHandler();
}

- (BOOL)prefersStatusBarHidden {
	return NO;
}

- (BOOL)shouldAutorotate {
	return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
	return UIInterfaceOrientationMaskAll;
}

@end
