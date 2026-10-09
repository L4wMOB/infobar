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

- (void)drawRect:(CGRect)rect {
	CGRect b = self.bounds;
	if (b.size.width < 4 || b.size.height < 4) return;
	CGContextRef ctx = UIGraphicsGetCurrentContext();

	CGFloat inset = 1.0;
	CGFloat w = b.size.width - 2 * inset, h = b.size.height - 2 * inset;
	CGFloat step = w / (IB_HISTORY_COUNT - 1);

	CGContextSaveGState(ctx);
	CGContextSetLineWidth(ctx, 0.5);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.13].CGColor);
	for (int i = 1; i < 4; i++) {
		CGFloat y = round(inset + h * i / 4.0) + 0.25;
		CGContextMoveToPoint(ctx, inset, y);
		CGContextAddLineToPoint(ctx, inset + w, y);
	}
	for (int i = 1; i < 6; i++) {
		CGFloat x = round(inset + w - i * 10 * step) + 0.25;
		if (x < inset) break;
		CGContextMoveToPoint(ctx, x, inset);
		CGContextAddLineToPoint(ctx, x, inset + h);
	}
	CGContextStrokePath(ctx);
	// Frame
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.28].CGColor);
	CGContextStrokeRect(ctx, CGRectInset(b, 0.25, 0.25));
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
	if (!isfinite(lo) || !isfinite(hi)) return; // no data yet
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
	if (range <= 0) return;

	CGFloat (^yFor)(double) = ^CGFloat(double v) {
		double norm = MIN(MAX((v - lo) / range, 0), 1);
		return inset + h - (CGFloat)norm * h;
	};

	CGContextSaveGState(ctx);
	CGContextClipToRect(ctx, b);

	NSUInteger seriesIndex = 0;
	for (NSArray<NSNumber *> *s in _series) {
		NSUInteger n = s.count;
		if (n >= 2) {
			UIBezierPath *line = [UIBezierPath bezierPath];
			CGPoint first = CGPointZero, last = CGPointZero;
			for (NSUInteger i = 0; i < n; i++) {
				CGPoint p = CGPointMake(inset + w - (CGFloat)(n - 1 - i) * step, yFor(s[i].doubleValue));
				if (i == 0) {
					[line moveToPoint:p];
					first = p;
				} else {
					[line addLineToPoint:p];
				}
				last = p;
			}
			line.lineJoinStyle = kCGLineJoinRound;
			line.lineCapStyle = kCGLineCapRound;

			BOOL banded = seriesIndex == 0 && _bandColors.count == 3 && _bandThresholds.count == 2;
			UIColor *plain = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];

			if (banded) {
				UIBezierPath *fill = [line copy];
				[fill addLineToPoint:CGPointMake(last.x, b.size.height)];
				[fill addLineToPoint:CGPointMake(first.x, b.size.height)];
				[fill closePath];
				line.lineWidth = 1.3;

				CGFloat yLow = yFor(_bandThresholds[0].doubleValue);
				CGFloat yHigh = yFor(_bandThresholds[1].doubleValue);
				CGRect rects[3] = {
					CGRectMake(0, yLow, b.size.width, b.size.height - yLow),
					CGRectMake(0, yHigh, b.size.width, yLow - yHigh),
					CGRectMake(0, 0, b.size.width, yHigh),
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
				double lastValue = s[n - 1].doubleValue;
				int level = lastValue < _bandThresholds[0].doubleValue ? 0 : (lastValue < _bandThresholds[1].doubleValue ? 1 : 2);
				[_bandColors[level] setFill];
				[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(last.x - 1.8, last.y - 1.8, 3.6, 3.6)] fill];
			} else {
				if (seriesIndex == 0) {
					UIBezierPath *fill = [line copy];
					[fill addLineToPoint:CGPointMake(last.x, b.size.height)];
					[fill addLineToPoint:CGPointMake(first.x, b.size.height)];
					[fill closePath];
					[[plain colorWithAlphaComponent:0.25] setFill];
					[fill fill];
				}
				line.lineWidth = seriesIndex == 0 ? 1.3 : 1.0;
				[plain setStroke];
				[line stroke];
			}
		}
		seriesIndex++;
	}
	CGContextRestoreGState(ctx);
}

@end
