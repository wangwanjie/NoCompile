//
//  ExBaseViewController.h
//  ObjC 基类控制器：App 里的 Swift / ObjC 页面都继承它（混合继承链）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExBaseViewController : UIViewController

/// 子类重写，返回导航标题
- (NSString *)exTitle;
/// 子类重写，搭建界面（在基类 viewDidLoad 里调用）
- (void)exSetupUI;
/// 基类提供的内容标签文本，场景 M05
- (NSString *)baseDescription;

@property (nonatomic, strong, readonly) UILabel *infoLabel;

@end

NS_ASSUME_NONNULL_END
