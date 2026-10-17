//
//  C01CppBridge.h
//  C++ 能力的纯 ObjC 出口，供 Swift 调用
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface C01CppBridge : NSObject

+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
