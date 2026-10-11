#import "IBController.h"
#import "IBOverlayWindow.h"
#import "IBBarView.h"
#import "IBPrefs.h"
#import "IBStats.h"
#import "IBFormatter.h"
#import <objc/message.h>
#import <notify.h>

static const CGFloat kMargin = 4;

@interface IBController () <IBBarViewDelegate>
@end

@implementation IBController {
	IBPrefs *_prefs;
	IBOverlayWindow *_window;
	IBOverlayViewController *_viewController;
	IBBarView *_bar;
	NSTimer *_timer;
	dispatch_queue_t _queue;
	BOOL _started;
	BOOL _refreshing;
	BOOL _tickPending;
	BOOL _animateNextLayout;
	BOOL _placed;
	BOOL _screenBlanked;
	CGSize _lastContainerSize;
	CGFloat _appliedExtraTop;
	CGFloat _appliedExtraBottom;
	int _blankToken;
}

+ (instancetype)sharedInstance {
	static IBController *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [[self alloc] init]; });
	return shared;
}

- (void)start {
	if (_started) return;
	_started = YES;
	_queue = dispatch_queue_create("com.mathelord.infobar.stats", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
	_prefs = [IBPrefs load];

	__weak typeof(self) weakSelf = self;
	int token;
	notify_register_dispatch(IB_NOTIFY_PREFS, &token, dispatch_get_main_queue(), ^(int t) { [weakSelf reloadPrefs]; });
	notify_register_dispatch(IB_NOTIFY_RESET, &token, dispatch_get_main_queue(), ^(int t) { [weakSelf resetPosition]; });
	notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) { [weakSelf updateVisibility]; });
	notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &_blankToken, dispatch_get_main_queue(), ^(int t) {
		IBController *strongSelf = weakSelf;
		if (!strongSelf) return;
		uint64_t state = 0;
		notify_get_state(t, &state);
		strongSelf->_screenBlanked = state != 0;
		[strongSelf updateVisibility];
	});

	[self createWindow];
	[_bar applyPrefs:_prefs];
	[self updateTouchThrough];
	dispatch_async(_queue, ^{ [[IBStats sharedInstance] refresh]; });
	[self updateVisibility];
	[self tick];
}

#pragma mark Window

- (UIWindowScene *)mainWindowScene {
	UIWindowScene *fallback = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		UIWindowScene *ws = (UIWindowScene *)scene;
		if (ws.screen == [UIScreen mainScreen]) return ws;
		if (!fallback) fallback = ws;
	}
	return fallback;
}

- (void)createWindow {
	UIWindowScene *scene = [self mainWindowScene];
	_window = scene ? [[IBOverlayWindow alloc] initWithWindowScene:scene] : [[IBOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	_window.frame = [UIScreen mainScreen].bounds;
	_window.windowLevel = 10000;
	_window.backgroundColor = [UIColor clearColor];
	_window.opaque = NO;

	_viewController = [IBOverlayViewController new];
	__weak typeof(self) weakSelf = self;
	_viewController.layoutHandler = ^{ [weakSelf containerDidLayout]; };
	_window.rootViewController = _viewController;

	_window.doubleTapHandler = ^{ [weakSelf windowDidDoubleTap]; };

	_bar = [[IBBarView alloc] initWithFrame:CGRectZero];
	_bar.delegate = self;
	[_viewController.view addSubview:_bar];
	_window.hidden = YES;
}

- (void)containerDidLayout {
	CGSize size = _viewController.view.bounds.size;
	if (CGSizeEqualToSize(size, _lastContainerSize)) return;
	_lastContainerSize = size;
	[self layoutBarFromPrefs:YES];
}

- (void)layoutBarFromPrefs:(BOOL)fromPrefs {
	UIView *container = _viewController.view;
	CGRect cb = container.bounds;
	if (cb.size.width < 1 || cb.size.height < 1) return;
	CGFloat W = cb.size.width, H = cb.size.height;
	CGSize size = [_bar preferredSizeForMaxWidth:W - 2 * kMargin];
	CGPoint center;

	if (fromPrefs || !_placed) {
		CGPoint rel = _prefs.position;
		if (rel.x < 0 || rel.y < 0) {
			CGFloat top = container.safeAreaInsets.top;
			center = CGPointMake(W / 2, MAX(top, 20) + size.height / 2 + 2);
		} else {
			center = CGPointMake(rel.x * W, rel.y * H);
		}
		_placed = YES;
	} else {
		if (_bar.isDragging) {
			_bar.bounds = CGRectMake(0, 0, size.width, size.height);
			return;
		}
		CGPoint oc = _bar.center;
		CGSize os = _bar.bounds.size;
		if (oc.x < W / 3) center.x = oc.x - os.width / 2 + size.width / 2;
		else if (oc.x > W * 2 / 3) center.x = oc.x + os.width / 2 - size.width / 2;
		else center.x = oc.x;
		CGFloat dTop = _prefs.bgExtendTop - _appliedExtraTop;
		CGFloat dBottom = _prefs.bgExtendBottom - _appliedExtraBottom;
		if (oc.y > H * 2 / 3) center.y = oc.y + os.height / 2 - size.height / 2 + dBottom;
		else center.y = oc.y - os.height / 2 + size.height / 2 - dTop;
	}
	_appliedExtraTop = _prefs.bgExtendTop;
	_appliedExtraBottom = _prefs.bgExtendBottom;

	center.x = MIN(MAX(center.x, kMargin + size.width / 2), W - kMargin - size.width / 2);
	center.y = MIN(MAX(center.y, kMargin + size.height / 2), H - kMargin - size.height / 2);
	_bar.bounds = CGRectMake(0, 0, size.width, size.height);
	_bar.center = center;
}

- (void)resetPosition {
	[IBPrefs setValue:nil forKey:@"posX"];
	[IBPrefs setValue:nil forKey:@"posY"];
	_prefs = [IBPrefs load];
	[UIView animateWithDuration:0.25 animations:^{ [self layoutBarFromPrefs:YES]; }];
}

#pragma mark Preferences & visibility

- (void)updateTouchThrough {
	_window.touchThrough = _prefs.pinned && _prefs.clickThrough;
}

- (void)windowDidDoubleTap {
	if (_prefs.doubleTapTogglesLayout && _window.touchThrough) [self barViewDidDoubleTap:_bar];
}

- (void)reloadPrefs {
	double oldInterval = _prefs.updateInterval;
	_prefs = [IBPrefs load];
	[_bar applyPrefs:_prefs];
	[self updateTouchThrough];
	if (_timer && fabs(oldInterval - _prefs.updateInterval) > 0.01) {
		[_timer invalidate];
		_timer = nil;
	}
	[self updateVisibility];
	[self tick];
}

- (BOOL)isUILocked {
	Class cls = NSClassFromString(@"SBLockScreenManager");
	if (![cls respondsToSelector:@selector(sharedInstance)]) return NO;
	id manager = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
	if (![manager respondsToSelector:@selector(isUILocked)]) return NO;
	return ((BOOL (*)(id, SEL))objc_msgSend)(manager, @selector(isUILocked));
}

- (BOOL)isLandscape {
	UIApplication *app = [UIApplication sharedApplication];
	SEL sel = @selector(activeInterfaceOrientation);
	if (![app respondsToSelector:sel]) return NO;
	UIInterfaceOrientation o = (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(app, sel);
	return UIInterfaceOrientationIsLandscape(o);
}

- (BOOL)updateVisibility {
	BOOL active = _prefs.enabled && !_screenBlanked;
	BOOL visible = active && (_prefs.showOnLockScreen || ![self isUILocked]) && !(_prefs.hideInLandscape && [self isLandscape]);
	_window.hidden = !visible;

	if (active && !_timer) {
		__weak typeof(self) weakSelf = self;
		_timer = [NSTimer timerWithTimeInterval:_prefs.updateInterval repeats:YES block:^(NSTimer *t) { [weakSelf tick]; }];
		_timer.tolerance = _prefs.updateInterval * 0.2; // lets the system batch wake-ups
		[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
	} else if (!active && _timer) {
		// Screen off / disabled: don't measure anything, saves battery
		[_timer invalidate];
		_timer = nil;
	}
	return visible;
}

- (void)tick {
	if (![self updateVisibility]) return;
	if (_refreshing) {
		_tickPending = YES;
		return;
	}
	_refreshing = YES;
	IBPrefs *prefs = _prefs;
	dispatch_async(_queue, ^{
		IBStats *stats = [IBStats sharedInstance];
		stats.measureCPUFrequency = prefs.showCPUFreq && !prefs.collapsed;
		// Only read what is shown: every reading costs battery
		BOOL buttonsOnly = prefs.collapsed && prefs.collapsedMode == IBCollapsedModeButtons;
		BOOL full = !prefs.collapsed;
		stats.measureCPU = !buttonsOnly && (full ? (prefs.showCPU || prefs.showCPUGraph) : prefs.collapsedShowCPU);
		stats.measureMemory = !buttonsOnly && (full ? (prefs.showRAMPercent || prefs.showRAMGB || prefs.showRAMGraph) : prefs.collapsedShowRAM);
		stats.measureBattery = !buttonsOnly && (full
			? (prefs.showBattery || prefs.showChargeGraph || prefs.showBatteryTemp || prefs.showTempGraph || prefs.showBatteryPower || prefs.showBatteryVoltage
			   || prefs.showCharger || prefs.showBatteryHealth || prefs.showBatteryCycles || prefs.showCyclesGraph)
			: (prefs.collapsedShowBattery || prefs.collapsedShowTemp));
		stats.measureNetwork = !buttonsOnly && (full ? (prefs.showNetwork || prefs.showNetworkGraph) : prefs.collapsedShowNetwork);
		stats.measureSystem = !buttonsOnly && (full
			? (prefs.showIP || prefs.showStorage || prefs.showUptime || prefs.showThermal)
			: (prefs.collapsedShowStorage || prefs.collapsedShowUptime || prefs.collapsedShowThermal));
		[stats refresh];
		NSArray<IBModule *> *modules = [IBFormatter modulesForStats:stats prefs:prefs];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_refreshing = NO;
			[self->_bar setModules:modules];
			if (self->_animateNextLayout) {
				// Animate collapsing / expanding
				self->_animateNextLayout = NO;
				[UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
					[self layoutBarFromPrefs:NO];
					[self->_bar layoutIfNeeded];
				} completion:nil];
			} else if (self->_placed) {
				// Size changes (value or graph switched on / off, longer text) glide
				[UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut animations:^{
					[self layoutBarFromPrefs:NO];
					[self->_bar layoutIfNeeded];
				} completion:nil];
			} else {
				[self layoutBarFromPrefs:NO];
			}
			// Preferences changed while measuring
			if (self->_tickPending) {
				self->_tickPending = NO;
				[self tick];
			}
		});
	});
}

#pragma mark IBBarViewDelegate

- (void)barViewDidTogglePin:(IBBarView *)bar {
	[IBPrefs setValue:@(bar.pinned) forKey:@"pinned"];
	_prefs = [IBPrefs load];
	[self updateTouchThrough];
}

- (void)barViewDidFinishDragging:(IBBarView *)bar {
	[UIView animateWithDuration:0.2 animations:^{ [self layoutBarFromPrefs:NO]; }];
	CGSize size = _viewController.view.bounds.size;
	if (size.width < 1 || size.height < 1) return;
	[IBPrefs setValue:@(bar.center.x / size.width) forKey:@"posX"];
	[IBPrefs setValue:@(bar.center.y / size.height) forKey:@"posY"];
	_prefs = [IBPrefs load];
}

- (void)barViewDidToggleCollapse:(IBBarView *)bar {
	[IBPrefs setValue:@(!_prefs.collapsed) forKey:@"collapsed"];
	_animateNextLayout = YES;
	[self reloadPrefs];
}

- (void)barViewDidDoubleTap:(IBBarView *)bar {
	IBLayout next = _prefs.layout == IBLayoutRow ? IBLayoutList : IBLayoutRow;
	[IBPrefs setValue:@(next) forKey:@"layout"];
	[self reloadPrefs];
}

@end
