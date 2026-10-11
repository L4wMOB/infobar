#import "IBOverlayWindow.h"

@implementation IBOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *view = [super hitTest:point withEvent:event];
	if (view == self || view == self.rootViewController.view) return nil;
	return view;
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
