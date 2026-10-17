//
//  B13ObjCException.m
//  场景 B13：@try/@catch/@finally 与自定义异常，异常展开穿过注入镜像的栈帧
//

#import "B13ObjCException.h"

@implementation B13ObjCException

+ (void)thrower {
    @throw [NSException exceptionWithName:@"B13Error" reason:@"B13(@@v1@@)" userInfo:@{@"k": @1}];
}

+ (NSString *)probe {
    NSString *result = @"none";
    @try {
        [self thrower];
    } @catch (NSException *exception) {
        result = [NSString stringWithFormat:@"%@:%@:%@", exception.name, exception.reason, exception.userInfo[@"k"]];
    } @finally {
        result = [result stringByAppendingString:@"+fin"];
    }
    return result;
}

@end
