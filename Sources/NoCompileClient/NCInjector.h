//
//  NCInjector.h
//  进程内注入核心：dlopen 新 dylib，并把新实现嫁接回运行中的旧实现
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NCInjectStatus) {
    NCInjectStatusSuccess = 0,
    NCInjectStatusLoadFailed,       // dlopen 失败
    NCInjectStatusNothingInjected,  // 加载成功但未替换任何实现（通常缺少 -interposable）
    NCInjectStatusLayoutChanged,    // 已弃用：内存布局变化不再拒绝注入，改为尽力注入并重建界面（见 layoutChangedClasses）
};

@interface NCInjectResult : NSObject
@property (nonatomic) NCInjectStatus status;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic) NSUInteger objcMethodsReplaced;
@property (nonatomic) NSUInteger swiftSlotsPatched;
@property (nonatomic) NSUInteger symbolsRebound;
@property (nonatomic, copy) NSArray<Class> *injectedClasses;
/// 发生内存布局变化（增删方法 / 存储属性）的类名。注入仍会进行，这些类的旧实例若未被重建，
/// 访问新成员可能异常，建议重新运行 App
@property (nonatomic, copy) NSArray<NSString *> *layoutChangedClasses;
/// 注入后被自动刷新的视图控制器类名
@property (nonatomic, copy) NSArray<NSString *> *refreshedControllers;
@end

@interface NCInjector : NSObject

/// 加载并注入一个 dylib。内部会串行执行，可在任意线程调用
+ (NCInjectResult *)injectDylibAtPath:(NSString *)dylibPath
                          sourceFiles:(nullable NSArray<NSString *> *)sourceFiles;

/// 同上。isNewFile 表示 dylib 来自 App 中原本没有的新增文件：
/// 以 RTLD_GLOBAL 加载，使之后注入的 dylib 能链接到其中的符号；没有可替换的实现也视为成功
+ (NCInjectResult *)injectDylibAtPath:(NSString *)dylibPath
                          sourceFiles:(nullable NSArray<NSString *> *)sourceFiles
                            isNewFile:(BOOL)isNewFile;

@end

NS_ASSUME_NONNULL_END
