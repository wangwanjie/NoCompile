//
//  CppBridge.h
//  把 C++ 能力以纯 ObjC 接口暴露给 Swift（头文件中不能出现 C++ 语法）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CppBridge : NSObject

+ (NSString *)message;

@end

NS_ASSUME_NONNULL_END
