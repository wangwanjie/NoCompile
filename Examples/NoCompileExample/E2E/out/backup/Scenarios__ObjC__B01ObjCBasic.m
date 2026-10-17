//
//  B01ObjCBasic.m
//  场景 B01：ObjC 类方法 / 实例方法 / 私有方法
//

#import "B01ObjCBasic.h"

@interface B01ObjCBasic ()
- (NSString *)privateMethod;
@end

@implementation B01ObjCBasic

+ (NSString *)classMethod {
    return @"B01(@@v1@@)";
}

- (NSString *)instanceMethod {
    return [NSString stringWithFormat:@"inst:%@", [self privateMethod]];
}

- (NSString *)privateMethod {
    return @"priv";
}

+ (NSString *)probe {
    return [NSString stringWithFormat:@"%@ %@", [self classMethod], [[B01ObjCBasic new] instanceMethod]];
}

@end
