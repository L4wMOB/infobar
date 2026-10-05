#import <UIKit/UIKit.h>

@class IBBarView, IBPrefs;

NS_ASSUME_NONNULL_BEGIN

@protocol IBBarViewDelegate <NSObject>
- (void)barViewDidTogglePin:(IBBarView *)bar;
- (void)barViewDidFinishDragging:(IBBarView *)bar;
- (void)barViewDidDoubleTap:(IBBarView *)bar;
- (void)barViewDidToggleCollapse:(IBBarView *)bar;
@end

@interface IBBarView : UIView
@property (nonatomic, weak, nullable) id<IBBarViewDelegate> delegate;
@property (nonatomic, getter=isPinned) BOOL pinned;
@property (nonatomic, readonly, getter=isDragging) BOOL dragging;
- (void)applyPrefs:(IBPrefs *)prefs;
- (void)setText:(NSAttributedString *)text;
// Size for the current text (within the maximum width)
- (CGSize)preferredSizeForMaxWidth:(CGFloat)maxWidth;
@end

NS_ASSUME_NONNULL_END
