//
//  ExHeaderUser.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 使用宏 / inline 函数的模块内类，用来验证头文件变更
@interface ExHeaderUser : NSObject

+ (NSString *)macroText;
+ (NSString *)inlineText;

@end

NS_ASSUME_NONNULL_END
