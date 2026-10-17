//
//  ExInline.h
//  头文件里的 static inline 函数：场景 H02（每个引用方都有一份拷贝，需要全部重编）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *ExInlineGreeting(void) {
    return @"@@v1@@";
}

/// 数值夹取，常见于 UI 工具库
static inline double ExClamp(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

NS_ASSUME_NONNULL_END
