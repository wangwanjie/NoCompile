//
//  ExPlayerEngine.h
//  纯 ObjC 接口（头文件里不出现 C++ 语法），实现在 .mm
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExPlayerEngine : NSObject

/// 场景 M08：静态库里的 ObjC++ 类
+ (NSString *)engineInfo;
/// 场景 B19：C++ 异常（自定义类型）在 .mm 内抛出并捕获
+ (NSString *)exceptionInfo;
/// 播放列表（C++ std::vector / std::map / lambda），场景 B15
+ (NSString *)playlistSummary;
/// 环形缓冲（头文件里的 C++ 模板），场景 H07
+ (NSString *)ringBufferSummary;
/// C 函数（ExAudioMath.c）
+ (NSString *)audioMathInfo;

@end

NS_ASSUME_NONNULL_END
