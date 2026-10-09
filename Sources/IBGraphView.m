#import "IBGraphView.h"
#import "IBStats.h"
#import <QuartzCore/QuartzCore.h>

static const CFTimeInterval kAnimDuration = 0.4;

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
	BOOL _rangeInit;
	double _curLo, _curHi;
	BOOL _rangeConverged;
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
		_rangeConverged = YES;
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

- (void)setSeries:(NSArray<NSArray<NSNumber *> *> *)series {
	NSArray *old = _series;
	series = [series copy] ?: @[];
	if ([series isEqualToArray:old]) return;
	_series = series;

	BOOL scroll = old.count > 0 && old.count == series.count && series.firstObject.count >= 2 && _rangeInit
		&& series.firstObject.count >= old.firstObject.count && series.firstObject.count <= old.firstObject.count + 1;
	if (scroll) {
		_progress = 0;
		_animStart = CACurrentMediaTime();
	} else {
		_progress = 1;
	}
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
	if (_progress < 1) _progress = MIN(1, (CACurrentMediaTime() - _animStart) / kAnimDuration);
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
	CGFloat eased = 1 - pow(1 - _progress, 3);
	CGFloat shift = (1 - eased) * step;

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
	double lo = INFINITY, hi = -INFINITY;
	for (NSArray<NSNumber *> *s in _series) {
		for (NSNumber *n in s) {
			double v = n.doubleValue;
			if (v < lo) lo = v;
			if (v > hi) hi = v;
		}
	}
	if (isfinite(lo) && isfinite(hi)) {
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
		double pad = (hi - lo) * 0.08;
		if (!fixedLo) lo -= pad;
		if (!fixedHi) hi += pad;

		if (!_rangeInit) {
			_curLo = lo;
			_curHi = hi;
			_rangeInit = YES;
		} else {
			double span = MAX(hi - lo, 1e-9);
			_curLo += (lo - _curLo) * 0.25;
			_curHi += (hi - _curHi) * 0.25;
			if (fabs(_curLo - lo) > span * 0.005 || fabs(_curHi - hi) > span * 0.005) {
				_rangeConverged = NO;
			} else {
				_curLo = lo;
				_curHi = hi;
			}
		}
		lo = _curLo;
		hi = _curHi;
		double range = hi - lo;

		if (range > 0) {
			CGFloat (^yFor)(double) = ^CGFloat(double v) {
				double norm = MIN(MAX((v - lo) / range, 0), 1);
				return H - (CGFloat)norm * H;
			};
			BOOL banded = _bandColors.count == 3 && _bandThresholds.count == 2;
			double currentValue = NAN;

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
					CGFloat startX = MIN(firstX, 0) - 2;
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

					CGFloat edgeY = lastY;
					if (shift > 0.01 && n >= 2) {
						CGFloat prevY = yFor(s[n - 2].doubleValue);
						CGFloat t = 1 - shift / step;
						edgeY = prevY + (lastY - prevY) * t;
					}

					UIColor *plain = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];
					if (seriesIndex == 0) {
						currentValue = s[n - 1].doubleValue;
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
						UIColor *dot = plain;
						if (banded) {
							double v = currentValue;
							dot = _bandColors[v < _bandThresholds[0].doubleValue ? 0 : (v < _bandThresholds[1].doubleValue ? 1 : 2)];
						}
						[dot setFill];
						[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(W - 4.5, edgeY - 1.8, 3.6, 3.6)] fill];
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

			if (H >= 18) {
				NSDictionary *attrs = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:6.5 weight:UIFontWeightSemibold],
										NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.9]};
				NSString *top = IBGraphFormat(_unit, hi * _valueScale + _valueOffset);
				NSString *bottom = IBGraphFormat(_unit, lo * _valueScale + _valueOffset);
				CGSize bs = [bottom sizeWithAttributes:attrs];
				[top drawAtPoint:CGPointMake(2.5, 0.5) withAttributes:attrs];
				[bottom drawAtPoint:CGPointMake(2.5, H - bs.height - 0.5) withAttributes:attrs];
				if (W >= 56 && !isnan(currentValue)) {
					NSString *cur = IBGraphFormat(_unit, currentValue * _valueScale + _valueOffset);
					CGSize cs = [cur sizeWithAttributes:attrs];
					[cur drawAtPoint:CGPointMake(W - cs.width - 7, 0.5) withAttributes:attrs];
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
