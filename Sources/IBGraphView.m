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

- (void)drawRect:(CGRect)rect {
	CGRect b = self.bounds;
	if (b.size.width < 4 || b.size.height < 4) return;

	// Background track
	[[UIColor colorWithWhite:1 alpha:0.08] setFill];
	[[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:3] fill];

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

	CGFloat inset = 1.5;
	CGFloat w = b.size.width - 2 * inset, h = b.size.height - 2 * inset;
	CGFloat step = w / (IB_HISTORY_COUNT - 1);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSaveGState(ctx);
	[[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:3] addClip];

	NSUInteger seriesIndex = 0;
	for (NSArray<NSNumber *> *s in _series) {
		NSUInteger n = s.count;
		UIColor *color = seriesIndex < _colors.count ? _colors[seriesIndex] : [UIColor whiteColor];
		if (n >= 2) {
			UIBezierPath *line = [UIBezierPath bezierPath];
			CGPoint first = CGPointZero, last = CGPointZero;
			for (NSUInteger i = 0; i < n; i++) {
				CGFloat x = inset + w - (CGFloat)(n - 1 - i) * step;
				double norm = MIN(MAX((s[i].doubleValue - lo) / range, 0), 1);
				CGFloat y = inset + h - (CGFloat)norm * h;
				CGPoint p = CGPointMake(x, y);
				if (i == 0) {
					[line moveToPoint:p];
					first = p;
				} else {
					[line addLineToPoint:p];
				}
				last = p;
			}
			if (seriesIndex == 0) {
				UIBezierPath *fill = [line copy];
				[fill addLineToPoint:CGPointMake(last.x, inset + h)];
				[fill addLineToPoint:CGPointMake(first.x, inset + h)];
				[fill closePath];
				[[color colorWithAlphaComponent:0.25] setFill];
				[fill fill];
			}
			line.lineWidth = 1.2;
			line.lineJoinStyle = kCGLineJoinRound;
			line.lineCapStyle = kCGLineCapRound;
			[color setStroke];
			[line stroke];
			// Marker on the newest sample
			[color setFill];
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(last.x - 1.5, last.y - 1.5, 3, 3)] fill];
		}
		seriesIndex++;
	}
	CGContextRestoreGState(ctx);
}

@end
