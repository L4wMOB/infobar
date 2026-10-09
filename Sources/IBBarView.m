#import "IBBarView.h"
#import "IBPrefs.h"
#import "IBFormatter.h"
#import "IBGraphView.h"

static const CGFloat kPadH = 8;
static const CGFloat kPadV = 5;
static const CGFloat kPinSize = 20;
static const CGFloat kCellGapH = 12;
static const CGFloat kLineGapRow = 4;
static const CGFloat kLineGapList = 3;
static const CGFloat kGraphGapBelow = 2;
static const CGFloat kMinGraphWidth = 44;

#pragma mark - Cell (one module: text + optional graph)

@interface IBCellView : UIView
@property (nonatomic, readonly) UILabel *label;
@property (nonatomic, readonly) IBGraphView *graph;
@end

@implementation IBCellView

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.userInteractionEnabled = NO;
		_label = [UILabel new];
		_label.numberOfLines = 0;
		_label.lineBreakMode = NSLineBreakByWordWrapping;
		_label.userInteractionEnabled = NO;
		[self addSubview:_label];
		_graph = [IBGraphView new];
		_graph.hidden = YES;
		[self addSubview:_graph];
	}
	return self;
}

@end

#pragma mark - Bar

@implementation IBBarView {
	UIVisualEffectView *_blurView;
	UIView *_tintView;
	UIButton *_pinButton;
	UIButton *_collapseButton;
	UIPanGestureRecognizer *_pan;
	UITapGestureRecognizer *_doubleTap;
	IBLayout _layout;
	BOOL _showPin;
	BOOL _showCollapse;
	BOOL _collapsed;
	CGPoint _panStartCenter;
	// Content
	NSArray<IBModule *> *_modules;
	NSMutableArray<IBCellView *> *_cells;
	CGFloat _graphHeight, _graphWidth;
	CGFloat _extraTop, _extraBottom;
	CGFloat _fontSize;
	// Widest width seen per module. Keeps the bar from growing and shrinking
	// when a value gets longer / shorter (5% -> 10%); reset when the set of
	// modules, the layout, the font or the available width changes.
	NSMutableDictionary<NSString *, NSNumber *> *_stickyWidths;
	NSString *_moduleSignature;
	CGFloat _lastMaxWidth;
	// Cached layout (relative to the bar), see -computeLayoutForMaxWidth:
	NSMutableArray<NSValue *> *_cellFrames;
	NSMutableArray<NSValue *> *_labelFrames;
	NSMutableArray<NSValue *> *_graphFrames;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.clipsToBounds = YES;
		self.layer.cornerCurve = kCACornerCurveContinuous;

		_cells = [NSMutableArray array];
		_modules = @[];
		_cellFrames = [NSMutableArray array];
		_labelFrames = [NSMutableArray array];
		_graphFrames = [NSMutableArray array];
		_graphHeight = 22;
		_graphWidth = 60;
		_stickyWidths = [NSMutableDictionary dictionary];
		_moduleSignature = @"";

		_blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
		_blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_blurView.userInteractionEnabled = NO;
		[self addSubview:_blurView];

		_tintView = [UIView new];
		_tintView.backgroundColor = [UIColor blackColor];
		_tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_tintView.userInteractionEnabled = NO;
		[self addSubview:_tintView];

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
	BOOL wasCollapsed = _collapsed;
	IBLayout oldLayout = _layout;
	_collapsed = prefs.collapsed;
	// Always a single row when collapsed
	_layout = _collapsed ? IBLayoutRow : prefs.layout;
	if (wasCollapsed != _collapsed || oldLayout != _layout || _fontSize != prefs.fontSize) {
		[_stickyWidths removeAllObjects];
		_fontSize = prefs.fontSize;
	}
	_showPin = prefs.showPinButton;
	_pinButton.hidden = !_showPin;
	// The button must stay visible while collapsed, otherwise there's no way back
	_showCollapse = prefs.showCollapseButton || _collapsed;
	_collapseButton.hidden = !_showCollapse;
	[self updateCollapseAppearance];
	_doubleTap.enabled = prefs.doubleTapTogglesLayout;

	_graphHeight = prefs.graphHeight;
	_graphWidth = prefs.graphWidth;
	_extraTop = prefs.bgExtendTop;
	_extraBottom = prefs.bgExtendBottom;

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

#pragma mark Content

- (void)setModules:(NSArray<IBModule *> *)modules {
	_modules = [modules copy] ?: @[];
	NSMutableString *signature = [NSMutableString string];
	for (IBModule *m in _modules) [signature appendFormat:@"%@|", m.identifier ?: @""];
	if (![signature isEqualToString:_moduleSignature]) {
		_moduleSignature = [signature copy];
		[_stickyWidths removeAllObjects]; // modules added / removed: size from scratch
	}
	while (_cells.count < _modules.count) {
		IBCellView *cell = [IBCellView new];
		[self insertSubview:cell belowSubview:_pinButton];
		[_cells addObject:cell];
	}
	for (NSUInteger i = 0; i < _cells.count; i++) {
		IBCellView *cell = _cells[i];
		if (i >= _modules.count) {
			cell.hidden = YES;
			continue;
		}
		IBModule *m = _modules[i];
		cell.hidden = NO;
		cell.label.attributedText = m.text;
		BOOL hasGraph = m.graphSeries.count > 0;
		cell.graph.hidden = !hasGraph;
		if (hasGraph) {
			IBGraphView *g = cell.graph;
			g.minValue = m.graphMin;
			g.maxValue = m.graphMax;
			g.minSpan = m.graphMinSpan > 0 ? m.graphMinSpan : 1;
			g.colors = m.graphColors;
			g.bandColors = m.graphBandColors;
			g.bandThresholds = m.graphThresholds;
			g.series = m.graphSeries; // redraws
		}
	}
	[self setNeedsLayout];
}

- (NSArray<UIButton *> *)visibleButtons {
	NSMutableArray *buttons = [NSMutableArray array];
	if (_showPin) [buttons addObject:_pinButton];
	if (_showCollapse) [buttons addObject:_collapseButton];
	return buttons;
}

- (BOOL)hasGraphAtIndex:(NSUInteger)i {
	return i < _modules.count && _modules[i].graphSeries.count > 0;
}

- (CGSize)computeLayoutForMaxWidth:(CGFloat)maxWidth {
	[_cellFrames removeAllObjects];
	[_labelFrames removeAllObjects];
	[_graphFrames removeAllObjects];

	NSUInteger nButtons = [self visibleButtons].count;
	BOOL list = _layout == IBLayoutList;
	CGFloat topPad = kPadV + _extraTop, botPad = kPadV + _extraBottom;
	CGFloat minH = nButtons == 0 ? 0 : (list ? nButtons * kPinSize + 6 : kPinSize + 4);
	minH += _extraTop + _extraBottom;

	if (_modules.count == 0) {
		// Buttons only (collapsed without values)
		return CGSizeMake(MAX(nButtons, 1) * kPinSize + 8, MAX(minH, kPinSize + 4 + _extraTop + _extraBottom));
	}

	CGFloat contentX = list ? kPadH : (nButtons > 0 ? 4 + nButtons * kPinSize + 2 : kPadH);
	CGFloat rightPad = list ? kPadH + (nButtons > 0 ? kPinSize + 2 : 0) : kPadH;
	CGFloat availW = MAX(20, maxWidth - contentX - rightPad);

	if (fabs(maxWidth - _lastMaxWidth) > 0.5) {
		_lastMaxWidth = maxWidth;
		[_stickyWidths removeAllObjects];
	}

	// Text sizes (measured the way the label really wraps so nothing is clipped).
	// A module never gets narrower than the widest it has been so far.
	NSUInteger n = _modules.count;
	CGSize labelSizes[n];
	CGFloat graphColumnW = 0;
	for (NSUInteger i = 0; i < n; i++) {
		CGSize ls = [_cells[i].label sizeThatFits:CGSizeMake(availW, CGFLOAT_MAX)];
		NSString *key = [NSString stringWithFormat:@"%lu-%@", (unsigned long)i, _modules[i].identifier ?: @""];
		CGFloat lw = MAX(ceil(MIN(ls.width, availW)), _stickyWidths[key].doubleValue);
		lw = MIN(lw, availW);
		_stickyWidths[key] = @(lw);
		labelSizes[i] = CGSizeMake(lw, ceil(ls.height));
		if ([self hasGraphAtIndex:i]) graphColumnW = MAX(graphColumnW, lw);
	}
	CGFloat gh = _graphHeight;

	CGFloat contentW = 0, contentH = 0;
	CGFloat x = 0, y = 0, lineH = 0;
	CGFloat listGraphW = MIN(MAX(_graphWidth, graphColumnW), availW);

	for (NSUInteger i = 0; i < n; i++) {
		BOOL hasGraph = [self hasGraphAtIndex:i];
		CGSize ls = labelSizes[i];
		CGFloat cw = ls.width;
		if (hasGraph) cw = list ? listGraphW : MIN(MAX(ls.width, kMinGraphWidth), availW);
		CGFloat ch = hasGraph ? ls.height + kGraphGapBelow + gh : ls.height;
		CGRect cell, label = CGRectMake(0, 0, ls.width, ls.height), graph = CGRectZero;
		if (hasGraph) graph = CGRectMake(0, ls.height + kGraphGapBelow, cw, gh);

		if (list) {
			cell = CGRectMake(0, y, cw, ch);
			y += ch + kLineGapList;
			contentW = MAX(contentW, cw);
			contentH = y - kLineGapList;
		} else {
			if (x > 0 && x + cw > availW) {
				// Wrap between modules
				y += lineH + kLineGapRow;
				x = 0;
				lineH = 0;
			}
			cell = CGRectMake(x, y, cw, ch);
			x += cw + kCellGapH;
			lineH = MAX(lineH, ch);
			contentW = MAX(contentW, CGRectGetMaxX(cell));
			contentH = y + lineH;
		}
		[_cellFrames addObject:[NSValue valueWithCGRect:cell]];
		[_labelFrames addObject:[NSValue valueWithCGRect:label]];
		[_graphFrames addObject:[NSValue valueWithCGRect:graph]];
	}

	CGFloat W = MIN(contentX + contentW + rightPad, maxWidth);
	CGFloat H = MAX(contentH + topPad + botPad, minH);
	// Center the content between the paddings (the buttons can make the bar taller)
	CGFloat offsetY = topPad + MAX(0, (H - topPad - botPad - contentH) / 2);
	for (NSUInteger i = 0; i < n; i++) {
		CGRect c = _cellFrames[i].CGRectValue;
		c.origin.x += contentX;
		c.origin.y += offsetY;
		_cellFrames[i] = [NSValue valueWithCGRect:c];
	}
	[self setNeedsLayout];
	return CGSizeMake(W, H);
}

- (CGSize)preferredSizeForMaxWidth:(CGFloat)maxWidth {
	return [self computeLayoutForMaxWidth:maxWidth];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect b = self.bounds;
	_blurView.frame = b;
	_tintView.frame = b;

	if (_cellFrames.count != _modules.count) [self computeLayoutForMaxWidth:b.size.width];

	NSArray<UIButton *> *buttons = [self visibleButtons];
	CGFloat contentTop = _extraTop, contentBottom = b.size.height - _extraBottom;
	for (NSUInteger i = 0; i < buttons.count; i++) {
		// bounds + center instead of frame since the pin may be rotated
		buttons[i].bounds = CGRectMake(0, 0, kPinSize, kPinSize);
		if (_layout == IBLayoutList)
			buttons[i].center = CGPointMake(b.size.width - 3 - kPinSize / 2, contentTop + 3 + kPinSize / 2 + i * kPinSize);
		else
			buttons[i].center = CGPointMake(4 + kPinSize / 2 + i * kPinSize, (contentTop + contentBottom) / 2);
	}

	for (NSUInteger i = 0; i < _cells.count; i++) {
		IBCellView *cell = _cells[i];
		if (i >= _modules.count || i >= _cellFrames.count) continue;
		cell.frame = _cellFrames[i].CGRectValue;
		cell.label.frame = _labelFrames[i].CGRectValue;
		if (!cell.graph.hidden) cell.graph.frame = _graphFrames[i].CGRectValue;
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
