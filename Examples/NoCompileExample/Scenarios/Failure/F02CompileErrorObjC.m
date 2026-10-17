//
//  F02CompileErrorObjC.m
//  场景 F02：ObjC 编译错误
//

#import <Foundation/Foundation.h>

@interface F02Host : NSObject
+ (NSString *)probe;
@end

@implementation F02Host

+ (NSString *)probe {
    NSString *value = @"F02(@@v1@@)";
    return value;
}

@end
