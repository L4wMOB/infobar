#import "IBGraphView.h"
#import "IBStats.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kLabelPad = 4;

static NSString *IBGraphFormat(IBGraphUnit unit, double v) {
	switch (unit) {
		case IBGraphUnitPercent: return [NSString stringWithFormat:@"%.0f%%", v];
		case IBGraphUnitDegrees: return [NSString stringWithFormat:@"%.0f°", v];
		case IBGraphUnitBytesPerSec:
			if (v < 0) v = 0;
			if (v >= 1048576) return [NSString stringWithFormat:@"%.1fM", v / 1048576];
			if (v >= 1024) return [NSString stringWithFormat:@"%.0fK", v / 1024];
			return [NSString stringWithFormat:@"%.0fB", v];
		default: return [NSString stringWithFormat:@"%.0f", v];
	}
}

#pragma mark - IBShadowLabel

@implementation IBShadowLabel

- (CGSize)fittingTextSizeForWidth:(CGFloat)width {
	return [super sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
}

- (void)setTextFrame:(CGRect)frame {
	self.frame = CGRectInset(frame, -kLabelPad, -kLabelPad);
}

- (void)drawTextInRect:(CGRect)rect {
	[super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(kLabelPad, kLabelPad, kLabelPad, kLabelPad))];
}

@end

#pragma mark - Plot (the moving part: lines and areas)

@class IBGraphView;

@interface IBGraphView ()
- (void)drawPlotInContext:(CGContextRef)ctx;
@end

@interface IBGraphPlot : UIView
@property (nonatomic, weak) IBGraphView *owner;
@end

@implementation IBGraphPlot

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
		self.userInteractionEnabled = NO;
		self.contentMode = UIViewContentModeRedraw;
	}
	return self;
}

- (void)drawRect:(CGRect)rect {
	[self.owner drawPlotInContext:UIGraphicsGetCurrentContext()];
}

@end

#pragma mark - IBGraphView

@implementation IBGraphView {
	IBGraphPlot *_plot;
	UIView *_frameView;
	IBShadowLabel *_maxLabel, *_minLabel, *_curLabel;
	CADisplayLink *_link;
	BOOL _rangeInit;
	double _curLo, _curHi;
	double _tLo, _tHi;
	CGSize _laidOutSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
		self.clipsToBounds = YES; // the plot is wider than the graph while it slides
		self.userInteractionEnabled = NO; // touches go to the bar (drag, double tap)
		self.contentMode = UIViewContentModeRedraw;
		_series = @[];
		_colors = @[];
		_bandColors = @[];
		_bandThresholds = @[];
		_thresholdColors = @[];
		_minValue = NAN;
		_maxValue = NAN;
		_minSpan = 1;
		_valueScale = 1;
		_scrollDuration = 1;
		_shadowStrength = 0.9;

		_plot = [[IBGraphPlot alloc] initWithFrame:CGRectZero];
		_plot.owner = self;
		[self addSubview:_plot];

		_frameView = [UIView new];
		_frameView.userInteractionEnabled = NO;
		_frameView.layer.borderWidth = 0.5;
		_frameView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
		[self addSubview:_frameView];

		_maxLabel = [self makeNumberLabel];
		_minLabel = [self makeNumberLabel];
		_curLabel = [self makeNumberLabel];
	}
	return self;
}

- (void)dealloc {
	[_link invalidate];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
	[super willMoveToWindow:newWindow];
	if (!newWindow) [self stopLink];
}

#pragma mark Properties

- (void)setColors:(NSArray<UIColor *> *)colors {
	_colors = [colors copy] ?: @[];
	[_plot setNeedsDisplay];
}

- (void)setBandColors:(NSArray<UIColor *> *)bandColors {
	_bandColors = [bandColors copy] ?: @[];
	[_plot setNeedsDisplay];
}

- (void)setBandThresholds:(NSArray<NSNumber *> *)bandThresholds {
	_bandThresholds = [bandThresholds copy] ?: @[];
	[_plot setNeedsDisplay];
}

- (void)setThresholdColors:(NSArray<UIColor *> *)thresholdColors {
	_thresholdColors = [thresholdColors copy] ?: @[];
	[_plot setNeedsDisplay];
}

- (void)setShadowStrength:(double)shadowStrength {
	if (fabs(shadowStrength - _shadowStrength) < 0.001) return;
	_shadowStrength = shadowStrength;
	_frameView.layer.shadowOpacity = (float)MIN(1.0, shadowStrength);
	[self setNeedsDisplay];
	[_plot setNeedsDisplay];
}

- (void)setSeries:(NSArray<NSArray<NSNumber *> *> *)series {
	NSArray *old = _series;
	series = [series copy] ?: @[];
	if ([series isEqualToArray:old]) return;
	_series = series;

	NSArray *newFirst = series.firstObject;
	NSArray *oldFirst = old.firstObject;
	NSUInteger newCount = newFirst.count, oldCount = oldFirst.count;
	BOOL slide = self.window && _rangeInit && old.count > 0 && old.count == series.count
		&& newCount >= 2 && newCount >= oldCount && newCount <= oldCount + 1;

	double lo, hi;
	if ([self targetRangeLo:&lo hi:&hi]) {
		_tLo = lo;
		_tHi = hi;
		if (!_rangeInit) {
			_curLo = lo;
			_curHi = hi;
			_rangeInit = YES;
		} else {
			double span = MAX(hi - lo, 1e-9);
			if (fabs(lo - _curLo) < span * 0.03 && fabs(hi - _curHi) < span * 0.03) {
				_curLo = lo;
				_curHi = hi;
			} else {
				[self startLink];
			}
		}
	}
	[_plot setNeedsDisplay];
	if (slide) [self animateSlide];
	[self updateNumbers];
}

#pragma mark Sliding

- (void)animateSlide {
	CGFloat step = self.bounds.size.width / (IB_HISTORY_COUNT - 1);
	if (step <= 0) return;
	CGFloat current = 0;
	if ([_plot.layer animationForKey:@"slide"]) {
		current = [[_plot.layer.presentationLayer valueForKeyPath:@"transform.translation.x"] doubleValue];
	}
	CGFloat from = MIN(step + current, 2 * step);
	CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
	a.fromValue = @(from);
	a.toValue = @0;
	a.duration = MIN(0.4, MAX(0.15, _scrollDuration * 0.4));
	a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
	[_plot.layer addAnimation:a forKey:@"slide"];
}

#pragma mark Scale easing (only after a big change of the range)

- (void)startLink {
	if (_link || !self.window) return;
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	_link.preferredFramesPerSecond = 30;
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopLink {
	[_link invalidate];
	_link = nil;
}

- (void)tick:(CADisplayLink *)link {
	CFTimeInterval dt = MAX(link.targetTimestamp - link.timestamp, 1.0 / 60);
	double k = 1 - exp(-dt * 8);
	_curLo += (_tLo - _curLo) * k;
	_curHi += (_tHi - _curHi) * k;
	double span = MAX(_tHi - _tLo, 1e-9);
	if (fabs(_curLo - _tLo) < span * 0.01 && fabs(_curHi - _tHi) < span * 0.01) {
		_curLo = _tLo;
		_curHi = _tHi;
		[self stopLink];
	}
	[_plot setNeedsDisplay];
}

#pragma mark Numbers

- (IBShadowLabel *)makeNumberLabel {
	IBShadowLabel *l = [IBShadowLabel new];
	l.userInteractionEnabled = NO;
	l.hidden = YES;
	[self addSubview:l];
	return l;
}

- (NSAttributedString *)numberString:(NSString *)text {
	NSShadow *shadow = [NSShadow new];
	shadow.shadowColor = [UIColor colorWithWhite:0 alpha:MIN(1.0, _shadowStrength)];
	shadow.shadowOffset = CGSizeMake(0, 0.5);
	shadow.shadowBlurRadius = 1.5;
	return [[NSAttributedString alloc] initWithString:text attributes:@{
		NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:6.5 weight:UIFontWeightSemibold],
		NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.92],
		NSShadowAttributeName: shadow,
	}];
}

// Sets a number; a changed number cross-dissolves into the new one
- (void)setText:(NSString *)text onLabel:(IBShadowLabel *)label {
	if ([label.attributedText.string isEqualToString:text]) return;
	NSAttributedString *attributed = [self numberString:text];
	if (label.attributedText.length == 0 || !self.window) {
		label.attributedText = attributed;
	} else {
		NSTimeInterval d = MIN(0.45, MAX(0.2, _scrollDuration * 0.5));
		[UIView transitionWithView:label duration:d
						   options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
						animations:^{ label.attributedText = attributed; }
						completion:nil];
	}
	[self setNeedsLayout];
}

- (void)updateNumbers {
	double lo, hi;
	NSArray<NSNumber *> *first = _series.firstObject;
	if (first.count == 0 || ![self targetRangeLo:&lo hi:&hi]) return;
	[self setText:IBGraphFormat(_unit, hi * _valueScale + _valueOffset) onLabel:_maxLabel];
	[self setText:IBGraphFormat(_unit, lo * _valueScale + _valueOffset) onLabel:_minLabel];
	[self setText:IBGraphFormat(_unit, first.lastObject.doubleValue * _valueScale + _valueOffset) onLabel:_curLabel];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
	CGFloat step = W / (IB_HISTORY_COUNT - 1);
	CGFloat margin = step + 3;
	_plot.frame = CGRectMake(-margin, 0, W + 2 * margin, H);
	_frameView.frame = self.bounds;
	CGPathRef outline = CGPathCreateCopyByStrokingPath([UIBezierPath bezierPathWithRect:self.bounds].CGPath, NULL, 0.5, kCGLineCapButt, kCGLineJoinMiter, 10);
	_frameView.layer.shadowPath = outline;
	CGPathRelease(outline);
	_frameView.layer.shadowColor = [UIColor blackColor].CGColor;
	_frameView.layer.shadowOpacity = (float)MIN(1.0, _shadowStrength);
	_frameView.layer.shadowRadius = 1.5;
	_frameView.layer.shadowOffset = CGSizeMake(0, 0.5);
	if (!CGSizeEqualToSize(_laidOutSize, self.bounds.size)) {
		_laidOutSize = self.bounds.size;
		[_plot setNeedsDisplay];
	}

	BOOL show = H >= 18 && _maxLabel.attributedText.length > 0;
	_maxLabel.hidden = _minLabel.hidden = !show;
	_curLabel.hidden = !(show && W >= 56);
	if (!show) return;
	CGSize ms = [_maxLabel fittingTextSizeForWidth:200];
	CGSize ns = [_minLabel fittingTextSizeForWidth:200];
	CGSize cs = [_curLabel fittingTextSizeForWidth:200];
	[_maxLabel setTextFrame:CGRectMake(2.5, 0.5, ceil(ms.width), ceil(ms.height))];
	[_minLabel setTextFrame:CGRectMake(2.5, H - ceil(ns.height) - 0.5, ceil(ns.width), ceil(ns.height))];
	[_curLabel setTextFrame:CGRectMake(W - ceil(cs.width) - 3, 0.5, ceil(cs.width), ceil(cs.height))];
}

#pragma mark Range

// Value range of the data (with headroom), before easing
- (BOOL)targetRangeLo:(double *)outLo hi:(double *)outHi {
	double lo = INFINITY, hi = -INFINITY;
	for (NSArray<NSNumber *> *s in _series) {
		for (NSNumber *n in s) {
			double v = n.doubleValue;
			if (v < lo) lo = v;
			if (v > hi) hi = v;
		}
	}
	if (!isfinite(lo) || !isfinite(hi)) return NO;
	BOOL fixedLo = !isnan(_minValue), fixedHi = !isnan(_maxValue);
	if (fixedLo) lo = _minValue;
	if (fixedHi) hi = _maxValue;
	if (hi - lo < _minSpan) {
		if (fixedLo) hi = lo + _minSpan;
		else if (fixedHi) lo = hi - _minSpan;
		else {
			double mid = (hi + lo) / 2;
			lo = mid - _minSpan / 2;
			hi = mid + _minSpan / 2;
		}
	}
	double pad = (hi - lo) * 0.08; // headroom for automatic edges
	if (!fixedLo) lo -= pad;
	if (!fixedHi) hi += pad;
	*outLo = lo;
	*outHi = hi;
	return YES;
}

#pragma mark Drawing

- (void)drawRect:(CGRect)rect {
	CGRect b = self.bounds;
	if (b.size.width < 4 || b.size.height < 4) return;
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGFloat W = b.size.width, H = b.size.height;
	CGFloat step = W / (IB_HISTORY_COUNT - 1);
	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.13].CGColor);
	CGContextSetShadowWithColor(ctx, CGSizeMake(0, 0.5), 1.5, [UIColor colorWithWhite:0 alpha:MIN(1.0, _shadowStrength)].CGColor);
	for (int i = 1; i < 4; i++) {
		CGFloat y = round(H * i / 4.0) + 0.25;
		CGContextMoveToPoint(ctx, 0, y);
		CGContextAddLineToPoint(ctx, W, y);
	}
	for (int i = 1; i < 6; i++) {
		CGFloat x = round(W - i * 10 * step) + 0.25;
		if (x < 0) break;
		CGContextMoveToPoint(ctx, x, 0);
		CGContextAddLineToPoint(ctx, x, H);
	}
	CGContextStrokePath(ctx);
}

- (void)drawPlotInContext:(CGContextRef)ctx {
	if (!_rangeInit) return;
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
	if (W < 4 || H < 4) return;
	CGFloat step = W / (IB_HISTORY_COUNT - 1);
	CGFloat M = step + 3; // the plot reaches this far beyond both edges
	double lo = _curLo, hi = _curHi, range = hi - lo;
	if (range <= 0) return;

	CGContextTranslateCTM(ctx, M, 0);
	CGContextClipToRect(ctx, CGRectMake(-M, 0, W + 2 * M, H));

	CGFloat (^yFor)(double) = ^CGFloat(double v) {
		double norm = MIN(MAX((v - lo) / range, 0), 1);
		return H - (CGFloat)norm * H;
	};
	BOOL banded = _bandColors.count == 3 && _bandThresholds.count == 2;
	UIColor *shadowColor = [UIColor colorWithWhite:0 alpha:MIN(1.0, _shadowStrength)];

	void (^strokeWithShadow)(UIBezierPath *) = ^(UIBezierPath *path) {
		CGContextSaveGState(ctx);
		NSShadow *shadow = [NSShadow new];
		shadow.shadowColor = shadowColor;
		shadow.shadowOffset = CGSizeMake(0, 1);
		shadow.shadowBlurRadius = 2;
		[shadow set];
		[path stroke];
		CGContextRestoreGState(ctx);
	};

	void (^fillWithShadow)(UIBezierPath *) = ^(UIBezierPath *path) {
		CGContextSaveGState(ctx);
		CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 2, shadowColor.CGColor);
		[path fill];
		CGContextRestoreGState(ctx);
	};

	NSUInteger seriesIndex = 0;
	for (NSArray<NSNumber *> *s in _series) {
		NSUInteger n = s.count;
		if (n >= 2) {
			UIBezierPath *line = [UIBezierPath bezierPath];
			CGFloat firstY = yFor(s[0].doubleValue), lastY = yFor(s[n - 1].doubleValue);
			CGFloat firstX = W - (CGFloat)(n - 1) * step;
			CGFloat endX = W + M;
			[line moveToPoint:CGPointMake(-M, firstY)];
			// Until the history is full the first value continues to the left edge
			if (firstX > -M) [line addLineToPoint:CGPointMake(firstX, firstY)];
			for (NSUInteger i = 0; i < n; i++) {
				[line addLineToPoint:CGPointMake(W - (CGFloat)(n - 1 - i) * step, yFor(s[i].doubleValue))];
			}
			[line addLineToPoint:CGPointMake(endX, lastY)];
			line.lineJoinStyle = kCGLineJoinRound;
			line.lineWidth = seriesIndex == 0 ? 1.3 : 1.0;

			UIColor *plain = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];
			if (seriesIndex == 0) {
				UIBezierPath *fill = [line copy];
				[fill addLineToPoint:CGPointMake(endX, H + 2)];
				[fill addLineToPoint:CGPointMake(-M, H + 2)];
				[fill closePath];
				if (banded) {
					CGFloat yLow = yFor(_bandThresholds[0].doubleValue);
					CGFloat yHigh = yFor(_bandThresholds[1].doubleValue);
					// Bands from the bottom: low, medium, high (each reaches both edges)
					CGRect rects[3] = {
						CGRectMake(-M, yLow, W + 2 * M, H + 2 - yLow),
						CGRectMake(-M, yHigh, W + 2 * M, yLow - yHigh),
						CGRectMake(-M, -2, W + 2 * M, yHigh + 2),
					};
					for (int k = 0; k < 3; k++) {
						if (rects[k].size.height <= 0) continue;
						CGContextSaveGState(ctx);
						CGContextClipToRect(ctx, rects[k]);
						[[_bandColors[k] colorWithAlphaComponent:0.30] setFill];
						fillWithShadow(fill);
						[_bandColors[k] setStroke];
						strokeWithShadow(line);
						CGContextRestoreGState(ctx);
					}
				} else {
					[[plain colorWithAlphaComponent:0.25] setFill];
					fillWithShadow(fill);
					[plain setStroke];
					strokeWithShadow(line);
				}
			} else {
				[plain setStroke];
				strokeWithShadow(line);
			}
		}
		seriesIndex++;
	}

	// Thin boundary lines over the whole width where yellow and red begin
	if (banded && _thresholdColors.count == 2) {
		CGContextSetLineWidth(ctx, 0.5);
		for (int k = 0; k < 2; k++) {
			double t = _bandThresholds[k].doubleValue;
			if (t <= lo || t >= hi) continue; // outside the visible range
			CGFloat y = round(yFor(t) * 2) / 2 + 0.25;
			CGContextSetStrokeColorWithColor(ctx, [_thresholdColors[k] colorWithAlphaComponent:0.8].CGColor);
			CGContextMoveToPoint(ctx, -M, y);
			CGContextAddLineToPoint(ctx, W + M, y);
			CGContextStrokePath(ctx);
		}
	}
}

@end
