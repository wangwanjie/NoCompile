//
//  ExBadgeLabel.h
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 自定义绘制的徽标视图（drawRect），场景 M06 / UI
@interface ExBadgeLabel : UIView

@property (nonatomic, copy) NSString *text;
/// 用来无界面验证：返回将要绘制的文案
- (NSString *)renderedText;

@end

NS_ASSUME_NONNULL_END
