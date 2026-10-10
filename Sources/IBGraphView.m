#import "IBGraphView.h"
#import "IBStats.h"
#import <QuartzCore/QuartzCore.h>

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

@implementation IBGraphView {
	CADisplayLink *_link;
	CFTimeInterval _animStart;
	CGFloat _progress;
	CFTimeInterval _animDuration;
	CGFloat _shiftFrom;
	BOOL _rangeInit;
	double _curLo, _curHi;
	CFTimeInterval _lastRangeTime;
	BOOL _rangeConverged;
	UILabel *_maxLabel, *_minLabel, *_curLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
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
		_progress = 1;
		_shiftFrom = 1;
		_scrollDuration = 1;
		_animDuration = 1;
		_rangeConverged = YES;
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

- (UILabel *)makeNumberLabel {
	UILabel *l = [UILabel new];
	l.font = [UIFont monospacedDigitSystemFontOfSize:6.5 weight:UIFontWeightSemibold];
	l.textColor = [UIColor colorWithWhite:1 alpha:0.9];
	l.userInteractionEnabled = NO;
	l.hidden = YES;
	[self addSubview:l];
	return l;
}

- (void)setText:(NSString *)text onLabel:(UILabel *)label {
	if ([label.text isEqualToString:text]) return;
	if (label.text.length == 0 || !self.window) {
		label.text = text;
		[self setNeedsLayout];
		return;
	}
	NSTimeInterval d = MIN(0.45, MAX(0.2, _scrollDuration * 0.5));
	[UIView transitionWithView:label duration:d
					   options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
					animations:^{ label.text = text; }
					completion:nil];
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
	BOOL show = H >= 18 && _maxLabel.text.length > 0;
	_maxLabel.hidden = _minLabel.hidden = !show;
	_curLabel.hidden = !(show && W >= 56);
	if (!show) return;
	CGSize ms = [_maxLabel sizeThatFits:CGSizeMake(200, 20)];
	CGSize ns = [_minLabel sizeThatFits:CGSizeMake(200, 20)];
	CGSize cs = [_curLabel sizeThatFits:CGSizeMake(200, 20)];
	_maxLabel.frame = CGRectMake(2.5, 0.5, ceil(ms.width), ceil(ms.height));
	_minLabel.frame = CGRectMake(2.5, H - ceil(ns.height) - 0.5, ceil(ns.width), ceil(ns.height));
	_curLabel.frame = CGRectMake(W - ceil(cs.width) - 3, 0.5, ceil(cs.width), ceil(cs.height));
}

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

- (void)setSeries:(NSArray<NSArray<NSNumber *> *> *)series {
	NSArray *old = _series;
	series = [series copy] ?: @[];
	if ([series isEqualToArray:old]) return;
	_series = series;

	NSArray *newFirst = series.firstObject;
	NSArray *oldFirst = old.firstObject;
	NSUInteger newCount = newFirst.count, oldCount = oldFirst.count;

	BOOL scroll = old.count > 0 && old.count == series.count && newCount >= 2 && _rangeInit
		&& newCount >= oldCount && newCount <= oldCount + 1;
	if (scroll) {
		CGFloat left = _progress < 1 ? _shiftFrom * (1 - _progress) : 0;
		_shiftFrom = MIN(1 + left, 2);
		_animDuration = MAX(0.2, _scrollDuration) * _shiftFrom;
		_progress = 0;
		_animStart = CACurrentMediaTime();
	} else {
		_shiftFrom = 1;
		_progress = 1;
	}
	[self updateNumbers];
	[self startLink];
	[self setNeedsDisplay];
}

- (void)setColors:(NSArray<UIColor *> *)colors {
	_colors = [colors copy] ?: @[];
	[self setNeedsDisplay];
}

- (void)setBandColors:(NSArray<UIColor *> *)bandColors {
	_bandColors = [bandColors copy] ?: @[];
	[self setNeedsDisplay];
}

- (void)setBandThresholds:(NSArray<NSNumber *> *)bandThresholds {
	_bandThresholds = [bandThresholds copy] ?: @[];
	[self setNeedsDisplay];
}

- (void)setThresholdColors:(NSArray<UIColor *> *)thresholdColors {
	_thresholdColors = [thresholdColors copy] ?: @[];
	[self setNeedsDisplay];
}

#pragma mark Animation

- (void)startLink {
	if (_link || !self.window) {
		if (!self.window) _progress = 1;
		return;
	}
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	_link.preferredFramesPerSecond = 30;
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopLink {
	[_link invalidate];
	_link = nil;
}

- (void)tick:(CADisplayLink *)link {
	if (_progress < 1) _progress = MIN(1, (CACurrentMediaTime() - _animStart) / _animDuration);
	[self setNeedsDisplay];
	if (_progress >= 1 && _rangeConverged) [self stopLink];
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	if (self.window && (_progress < 1 || !_rangeConverged)) [self startLink];
}

#pragma mark Drawing

- (void)drawRect:(CGRect)rect {
	CGRect b = self.bounds;
	if (b.size.width < 4 || b.size.height < 4) return;
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGFloat W = b.size.width, H = b.size.height;

	CGFloat step = W / (IB_HISTORY_COUNT - 1);
	CGFloat shift = _shiftFrom * (1 - _progress) * step;

	CGContextSaveGState(ctx);
	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.13].CGColor);
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
	CGContextRestoreGState(ctx);

	// Target value range
	_rangeConverged = YES;
	double lo, hi;
	if ([self targetRangeLo:&lo hi:&hi]) {
		if (!_rangeInit) {
			_curLo = lo;
			_curHi = hi;
			_rangeInit = YES;
		} else {
			double span = MAX(hi - lo, 1e-9);
			CFTimeInterval now = CACurrentMediaTime();
			double dt = MIN(MAX(now - _lastRangeTime, 0.0), 0.1);
			double k = 1 - exp(-dt * 7); // same speed whatever the frame rate
			_curLo += (lo - _curLo) * k;
			_curHi += (hi - _curHi) * k;
			if (fabs(_curLo - lo) > span * 0.005 || fabs(_curHi - hi) > span * 0.005) {
				_rangeConverged = NO;
			} else {
				_curLo = lo;
				_curHi = hi;
			}
		}
		_lastRangeTime = CACurrentMediaTime();
		lo = _curLo;
		hi = _curHi;
		double range = hi - lo;

		if (range > 0) {
			CGFloat (^yFor)(double) = ^CGFloat(double v) {
				double norm = MIN(MAX((v - lo) / range, 0), 1);
				return H - (CGFloat)norm * H;
			};
			BOOL banded = _bandColors.count == 3 && _bandThresholds.count == 2;

			CGContextSaveGState(ctx);
			CGContextClipToRect(ctx, b);

			NSUInteger seriesIndex = 0;
			for (NSArray<NSNumber *> *s in _series) {
				NSUInteger n = s.count;
				if (n >= 2) {
					UIBezierPath *line = [UIBezierPath bezierPath];
					CGFloat firstY = yFor(s[0].doubleValue), lastY = yFor(s[n - 1].doubleValue);
					CGFloat firstX = W - (CGFloat)(n - 1) * step + shift;
					CGFloat lastX = W + shift;
					CGFloat startX = MIN(firstX, 0) - 2; // beyond the edges so no cap shows
					[line moveToPoint:CGPointMake(startX, firstY)];
					if (firstX > 0) [line addLineToPoint:CGPointMake(firstX, firstY)];
					for (NSUInteger i = 0; i < n; i++) {
						[line addLineToPoint:CGPointMake(W - (CGFloat)(n - 1 - i) * step + shift, yFor(s[i].doubleValue))];
					}
					CGFloat endX = lastX;
					if (lastX < W + 2) {
						endX = W + 2;
						[line addLineToPoint:CGPointMake(endX, lastY)];
					}
					line.lineJoinStyle = kCGLineJoinRound;

					UIColor *plain = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];
					if (seriesIndex == 0) {
						UIBezierPath *fill = [line copy];
						[fill addLineToPoint:CGPointMake(endX, H + 2)];
						[fill addLineToPoint:CGPointMake(startX, H + 2)];
						[fill closePath];
						if (banded) {
							line.lineWidth = 1.3;
							CGFloat yLow = yFor(_bandThresholds[0].doubleValue);
							CGFloat yHigh = yFor(_bandThresholds[1].doubleValue);
							CGRect rects[3] = {
								CGRectMake(-2, yLow, W + 4, H + 2 - yLow),
								CGRectMake(-2, yHigh, W + 4, yLow - yHigh),
								CGRectMake(-2, -2, W + 4, yHigh + 2),
							};
							for (int k = 0; k < 3; k++) {
								if (rects[k].size.height <= 0) continue;
								CGContextSaveGState(ctx);
								CGContextClipToRect(ctx, rects[k]);
								[[_bandColors[k] colorWithAlphaComponent:0.30] setFill];
								[fill fill];
								[_bandColors[k] setStroke];
								[line stroke];
								CGContextRestoreGState(ctx);
							}
						} else {
							[[plain colorWithAlphaComponent:0.25] setFill];
							[fill fill];
							line.lineWidth = 1.3;
							[plain setStroke];
							[line stroke];
						}
					} else {
						line.lineWidth = 1.0;
						[plain setStroke];
						[line stroke];
					}
				}
				seriesIndex++;
			}

			if (banded && _thresholdColors.count == 2) {
				CGContextSetLineWidth(ctx, 0.5);
				for (int k = 0; k < 2; k++) {
					double t = _bandThresholds[k].doubleValue;
					if (t <= lo || t >= hi) continue; // outside the visible range
					CGFloat y = round(yFor(t) * 2) / 2 + 0.25;
					CGContextSetStrokeColorWithColor(ctx, [_thresholdColors[k] colorWithAlphaComponent:0.8].CGColor);
					CGContextMoveToPoint(ctx, 0, y);
					CGContextAddLineToPoint(ctx, W, y);
					CGContextStrokePath(ctx);
				}
			}

			CGContextRestoreGState(ctx);
		}
	}

	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.28].CGColor);
	CGContextStrokeRect(ctx, CGRectInset(b, 0.25, 0.25));

	if (!_rangeConverged && !_link) dispatch_async(dispatch_get_main_queue(), ^{ [self startLink]; });
}

@end
