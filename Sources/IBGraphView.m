#import "IBGraphView.h"
#import "IBStats.h"

@implementation IBGraphView

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
	}
	return self;
}

- (void)setSeries:(NSArray<NSArray<NSNumber *> *> *)series {
	_series = [series copy] ?: @[];
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

- (void)drawRect:(CGRect)rect {
	CGRect b = self.bounds;
	if (b.size.width < 4 || b.size.height < 4) return;
	CGContextRef ctx = UIGraphicsGetCurrentContext();

	CGFloat step = b.size.width / (IB_HISTORY_COUNT - 1);
	CGFloat bottom = b.size.height;

	CGContextSaveGState(ctx);
	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.13].CGColor);
	for (int i = 1; i < 4; i++) {
		CGFloat y = round(b.size.height * i / 4.0) + 0.25;
		CGContextMoveToPoint(ctx, 0, y);
		CGContextAddLineToPoint(ctx, b.size.width, y);
	}
	for (int i = 1; i < 6; i++) {
		CGFloat x = round(b.size.width - i * 10 * step) + 0.25;
		if (x < 0) break;
		CGContextMoveToPoint(ctx, x, 0);
		CGContextAddLineToPoint(ctx, x, b.size.height);
	}
	CGContextStrokePath(ctx);
	CGContextRestoreGState(ctx);

	// Value range
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
		double pad = (hi - lo) * 0.08; // headroom for automatic edges
		if (!fixedLo) lo -= pad;
		if (!fixedHi) hi += pad;
		double range = hi - lo;

		if (range > 0) {
			CGFloat (^yFor)(double) = ^CGFloat(double v) {
				double norm = MIN(MAX((v - lo) / range, 0), 1);
				return b.size.height - (CGFloat)norm * b.size.height;
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
					CGFloat firstX = b.size.width - (CGFloat)(n - 1) * step;
					CGFloat startX = MIN(firstX, 0) - 2;
					CGFloat endX = b.size.width + 2;
					[line moveToPoint:CGPointMake(startX, firstY)];
					if (firstX > 0) [line addLineToPoint:CGPointMake(firstX, firstY)];
					for (NSUInteger i = 0; i < n; i++) {
						[line addLineToPoint:CGPointMake(b.size.width - (CGFloat)(n - 1 - i) * step, yFor(s[i].doubleValue))];
					}
					[line addLineToPoint:CGPointMake(endX, lastY)];
					line.lineJoinStyle = kCGLineJoinRound;

					UIColor *plain = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];
					if (seriesIndex == 0) {
						UIBezierPath *fill = [line copy];
						[fill addLineToPoint:CGPointMake(endX, bottom + 2)];
						[fill addLineToPoint:CGPointMake(startX, bottom + 2)];
						[fill closePath];
						if (banded) {
							line.lineWidth = 1.3;
							CGFloat yLow = yFor(_bandThresholds[0].doubleValue);
							CGFloat yHigh = yFor(_bandThresholds[1].doubleValue);
							CGRect rects[3] = {
								CGRectMake(-2, yLow, b.size.width + 4, b.size.height + 2 - yLow),
								CGRectMake(-2, yHigh, b.size.width + 4, yLow - yHigh),
								CGRectMake(-2, -2, b.size.width + 4, yHigh + 2),
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
							double v = s[n - 1].doubleValue;
							dot = _bandColors[v < _bandThresholds[0].doubleValue ? 0 : (v < _bandThresholds[1].doubleValue ? 1 : 2)];
						}
						[dot setFill];
						[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(b.size.width - 4.5, lastY - 1.8, 3.6, 3.6)] fill];
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
					CGContextAddLineToPoint(ctx, b.size.width, y);
					CGContextStrokePath(ctx);
				}
			}
			CGContextRestoreGState(ctx);
		}
	}

	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.28].CGColor);
	CGContextStrokeRect(ctx, CGRectInset(b, 0.25, 0.25));
}

@end
