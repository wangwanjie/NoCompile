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
    NCInjectStatusLayoutChanged,    // 内存布局变化（增删存储属性 / 方法），拒绝注入
};

@interface NCInjectResult : NSObject
@property (nonatomic) NCInjectStatus status;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic) NSUInteger objcMethodsReplaced;
@property (nonatomic) NSUInteger swiftSlotsPatched;
@property (nonatomic) NSUInteger symbolsRebound;
@property (nonatomic, copy) NSArray<Class> *injectedClasses;
@end

@interface NCInjector : NSObject

/// 加载并注入一个 dylib。内部会串行执行，可在任意线程调用
+ (NCInjectResult *)injectDylibAtPath:(NSString *)dylibPath
                          sourceFiles:(nullable NSArray<NSString *> *)sourceFiles;

@end

NS_ASSUME_NONNULL_END
