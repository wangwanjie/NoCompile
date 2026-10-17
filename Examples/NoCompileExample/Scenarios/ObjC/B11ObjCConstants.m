//
//  B11ObjCConstants.m
//  场景 B11：本工程内的 extern 常量。使用方读取的是数据符号
//

#import "B11ObjCConstants.h"

NSString *const B11Title = @"B11(@@v1@@)";
const NSInteger B11Limit = 10;

@implementation B11ObjCConstants

+ (NSString *)probe {
    return [NSString stringWithFormat:@"%@ limit=%ld", B11Title, (long)B11Limit];
}

@end
