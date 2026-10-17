//
//  ExCardCell.h
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// ObjC 的 UITableViewCell 子类，被 Swift 页面复用（场景 UI-cell）
@interface ExCardCell : UITableViewCell

+ (NSString *)reuseIdentifier;
- (void)configureWithTitle:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
