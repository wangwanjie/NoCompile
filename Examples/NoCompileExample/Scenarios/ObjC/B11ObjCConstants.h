//
//  B11ObjCConstants.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 外部字符串常量 / 整型常量 / 结构体常量：数据符号
FOUNDATION_EXPORT NSString *const B11Title;
FOUNDATION_EXPORT const NSInteger B11Limit;

@interface B11ObjCConstants : NSObject

+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
