#import <UIKit/UIKit.h>

@class IBBarView, IBPrefs, IBModule;

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
- (void)setModules:(NSArray<IBModule *> *)modules;
// Size for the current content (within the maximum width)
- (CGSize)preferredSizeForMaxWidth:(CGFloat)maxWidth;
@end

NS_ASSUME_NONNULL_END
