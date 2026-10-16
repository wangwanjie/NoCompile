//
//  NCSweeper.h
//  注入后的零侵入刷新
//
//  默认行为（无需在业务代码里写任何东西）：
//  找到当前可见、且受本次注入影响的视图控制器（自身类被替换，或其视图层级里有被替换的视图类），
//  清空其视图后重新走 viewDidLoad → viewWillAppear → viewDidAppear，界面即按新代码重建。
//
//  兼容项（可选）：若类实现了 InjectionIII 风格的 -injected / +injected，则优先调用它们。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NCSweeper : NSObject

/// 在主线程执行刷新，返回被刷新的视图控制器类名（用于提示）
/// @param patchedClasses 被替换实现的旧类（App 中正在使用的类对象）
/// @param addedClasses   本次新增的类
+ (NSArray<NSString *> *)refreshAfterPatchingClasses:(NSArray<Class> *)patchedClasses
                                        addedClasses:(NSArray<Class> *)addedClasses
                                         sourceFiles:(nullable NSArray<NSString *> *)sourceFiles;

/// 资源更新后在主线程刷新界面，返回被刷新的视图控制器类名
/// @param kind storyboard / nib / image
/// @param name storyboard 名、nib 名或图片名。storyboard / nib 优先刷新由它加载的可见控制器，
///             找不到（如 xib 用于 cell、图片被代码引用）时刷新最上层的可见业务控制器
+ (NSArray<NSString *> *)refreshAfterResourceKind:(NSString *)kind name:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
