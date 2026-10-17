//
//  ExConstants.h
//  常量、枚举、C 结构体：头文件变更会影响所有引用它的实现文件
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 外部常量（数据符号），取值在 ExConstants.m
FOUNDATION_EXPORT NSString *const ExStatusToken;

/// 播放模式：用于验证"头文件里的枚举变化 → 依赖它的 .m 重编"
typedef NS_ENUM(NSInteger, ExPlayMode) {
    ExPlayModeSequence = 0,
    ExPlayModeLoop,
    ExPlayModeShuffle,
};

/// 值类型结构体，函数按值返回
typedef struct {
    double x;
    double y;
    int tag;
} ExPoint;

FOUNDATION_EXPORT ExPoint ExPointMake(double x, double y);
FOUNDATION_EXPORT NSString *ExPlayModeName(ExPlayMode mode);

NS_ASSUME_NONNULL_END
