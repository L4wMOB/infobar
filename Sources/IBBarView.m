#import "IBBarView.h"
#import "IBPrefs.h"

static const CGFloat kPadH = 8;
static const CGFloat kPadV = 5;
static const CGFloat kPinSize = 20;

@implementation IBBarView {
	UIVisualEffectView *_blurView;
	UIView *_tintView;
	UILabel *_label;
	UIButton *_pinButton;
	UIButton *_collapseButton;
	UIPanGestureRecognizer *_pan;
	UITapGestureRecognizer *_doubleTap;
	IBLayout _layout;
	BOOL _showPin;
	BOOL _showCollapse;
	BOOL _collapsed;
	CGPoint _panStartCenter;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.clipsToBounds = YES;
		self.layer.cornerCurve = kCACornerCurveContinuous;

		_blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
		_blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_blurView.userInteractionEnabled = NO;
		[self addSubview:_blurView];

		_tintView = [UIView new];
		_tintView.backgroundColor = [UIColor blackColor];
		_tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_tintView.userInteractionEnabled = NO;
		[self addSubview:_tintView];

		_label = [UILabel new];
		_label.numberOfLines = 0;
		_label.lineBreakMode = NSLineBreakByWordWrapping;
		_label.userInteractionEnabled = NO;
		[self addSubview:_label];

		_pinButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[_pinButton addTarget:self action:@selector(pinTapped) forControlEvents:UIControlEventTouchUpInside];
		_pinButton.accessibilityLabel = @"Pin InfoBar";
		[self addSubview:_pinButton];

		_collapseButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[_collapseButton addTarget:self action:@selector(collapseTapped) forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:_collapseButton];

		_pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
		_pan.maximumNumberOfTouches = 1;
		[self addGestureRecognizer:_pan];

		_doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
		_doubleTap.numberOfTapsRequired = 2;
		_doubleTap.delaysTouchesEnded = NO; // buttons should respond immediately
		[self addGestureRecognizer:_doubleTap];

		_showPin = YES;
		_showCollapse = YES;
		[self updatePinAppearance];
		[self updateCollapseAppearance];
	}
	return self;
}

#pragma mark Preferences

- (void)applyPrefs:(IBPrefs *)prefs {
	_collapsed = prefs.collapsed;
	// Always a single row when collapsed
	_layout = _collapsed ? IBLayoutRow : prefs.layout;
	_showPin = prefs.showPinButton;
	_pinButton.hidden = !_showPin;
	// The button must stay visible while collapsed, otherwise there's no way back
	_showCollapse = prefs.showCollapseButton || _collapsed;
	_collapseButton.hidden = !_showCollapse;
	[self updateCollapseAppearance];
	_doubleTap.enabled = prefs.doubleTapTogglesLayout;

	BOOL blur = prefs.useBlur && prefs.backgroundAlpha > 0.02;
	_blurView.hidden = !blur;
	// With blur, a lighter tint gives the same perceived opacity
	_tintView.alpha = blur ? prefs.backgroundAlpha * 0.6 : prefs.backgroundAlpha;
	self.layer.cornerRadius = prefs.cornerRadius;
	self.pinned = prefs.pinned;
	[self setNeedsLayout];
}

- (void)setPinned:(BOOL)pinned {
	_pinned = pinned;
	_pan.enabled = !pinned; // cancels an ongoing drag
	[self updatePinAppearance];
}

- (void)updatePinAppearance {
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
	UIImage *img = [UIImage systemImageNamed:(_pinned ? @"pin.fill" : @"pin") withConfiguration:config];
	UIColor *color = _pinned ? [UIColor colorWithRed:1.0 green:0.6 blue:0.15 alpha:1] : [UIColor colorWithWhite:1 alpha:0.6];
	[_pinButton setImage:[img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
	_pinButton.transform = _pinned ? CGAffineTransformIdentity : CGAffineTransformMakeRotation(M_PI_4);
	_pinButton.accessibilityValue = _pinned ? @"pinned" : @"unpinned";
}

- (void)updateCollapseAppearance {
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
	NSString *name = _collapsed ? @"chevron.right" : (_layout == IBLayoutList ? @"chevron.up" : @"chevron.left");
	UIImage *img = [UIImage systemImageNamed:name withConfiguration:config];
	[_collapseButton setImage:[img imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.75] renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
	_collapseButton.accessibilityLabel = _collapsed ? @"Expand InfoBar" : @"Collapse InfoBar";
}

#pragma mark Content & layout

- (void)setText:(NSAttributedString *)text {
	_label.attributedText = text;
	[self setNeedsLayout];
}

- (NSArray<UIButton *> *)visibleButtons {
	NSMutableArray *buttons = [NSMutableArray array];
	if (_showPin) [buttons addObject:_pinButton];
	if (_showCollapse) [buttons addObject:_collapseButton];
	return buttons;
}

- (BOOL)hasText {
	return _label.attributedText.length > 0;
}

// Space taken by the buttons next to the text
- (CGFloat)buttonSpace {
	NSUInteger n = [self visibleButtons].count;
	if (n == 0) return 0;
	if (_layout == IBLayoutList) return kPinSize + 2;
	return n * kPinSize + 2;
}

- (CGSize)preferredSizeForMaxWidth:(CGFloat)maxWidth {
	NSUInteger n = [self visibleButtons].count;
	CGFloat minH = n == 0 ? 0 : (_layout == IBLayoutList ? n * kPinSize + 6 : kPinSize + 4);
	if (![self hasText]) {
		// Buttons only (collapsed without values)
		return CGSizeMake(MAX(n, 1) * kPinSize + 8, MAX(minH, kPinSize + 4));
	}
	CGFloat textMax = MAX(20, maxWidth - 2 * kPadH - [self buttonSpace]);
	// Measure the way the label actually wraps so no line gets clipped
	CGSize text = [_label sizeThatFits:CGSizeMake(textMax, CGFLOAT_MAX)];
	CGFloat w = ceil(MIN(text.width, textMax)) + 2 * kPadH + [self buttonSpace];
	CGFloat h = MAX(ceil(text.height) + 2 * kPadV, minH);
	return CGSizeMake(MIN(w, maxWidth), h);
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect b = self.bounds;
	_blurView.frame = b;
	_tintView.frame = b;
	NSArray<UIButton *> *buttons = [self visibleButtons];
	_label.hidden = ![self hasText];
	for (NSUInteger i = 0; i < buttons.count; i++) {
		// bounds + center instead of frame since the pin may be rotated
		buttons[i].bounds = CGRectMake(0, 0, kPinSize, kPinSize);
		if (_layout == IBLayoutList)
			buttons[i].center = CGPointMake(b.size.width - 3 - kPinSize / 2, 3 + kPinSize / 2 + i * kPinSize);
		else
			buttons[i].center = CGPointMake(4 + kPinSize / 2 + i * kPinSize, b.size.height / 2);
	}
	if (_layout == IBLayoutList) {
		// Buttons stacked top right, text on the left
		_label.frame = CGRectMake(kPadH, kPadV, b.size.width - 2 * kPadH - [self buttonSpace], b.size.height - 2 * kPadV);
	} else {
		// Buttons side by side on the left, text next to them
		CGFloat x = buttons.count > 0 ? 4 + buttons.count * kPinSize + 2 : kPadH;
		_label.frame = CGRectMake(x, kPadV, b.size.width - x - kPadH, b.size.height - 2 * kPadV);
	}
}

#pragma mark Gestures

- (void)pinTapped {
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	self.pinned = !self.pinned;
	[self.delegate barViewDidTogglePin:self];
}

- (void)collapseTapped {
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	[self.delegate barViewDidToggleCollapse:self];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
	UIView *container = self.superview;
	if (!container) return;
	switch (pan.state) {
		case UIGestureRecognizerStateBegan: {
			_panStartCenter = self.center;
			_dragging = YES;
			[UIView animateWithDuration:0.15 animations:^{ self.transform = CGAffineTransformMakeScale(1.05, 1.05); }];
			break;
		}
		case UIGestureRecognizerStateChanged: {
			CGPoint t = [pan translationInView:container];
			self.center = CGPointMake(_panStartCenter.x + t.x, _panStartCenter.y + t.y);
			break;
		}
		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled:
		case UIGestureRecognizerStateFailed: {
			_dragging = NO;
			[UIView animateWithDuration:0.2 animations:^{ self.transform = CGAffineTransformIdentity; }];
			[self.delegate barViewDidFinishDragging:self];
			break;
		}
		default:
			break;
	}
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
	if (tap.state == UIGestureRecognizerStateRecognized) [self.delegate barViewDidDoubleTap:self];
}

// Give the small buttons a more forgiving hit area
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	if (!self.hidden && [self pointInside:point withEvent:event]) {
		UIButton *best = nil;
		CGFloat bestDist = CGFLOAT_MAX;
		for (UIButton *button in [self visibleButtons]) {
			CGFloat dx = fabs(point.x - button.center.x), dy = fabs(point.y - button.center.y);
			if (dx <= kPinSize / 2 + 6 && dy <= kPinSize / 2 + 6 && dx + dy < bestDist) {
				best = button;
				bestDist = dx + dy;
			}
		}
		if (best) return best;
	}
	return [super hitTest:point withEvent:event];
}

@end
