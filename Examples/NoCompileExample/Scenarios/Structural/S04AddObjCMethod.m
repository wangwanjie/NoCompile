//
//  S04AddObjCMethod.m
//  场景 S04：给 ObjC 类增加方法，头文件与实现一起改（一次保存两个文件）
//

#import "S04AddObjCMethod.h"

@implementation S04AddObjCMethod

- (NSString *)base {
    return @"S04-base";
}
// S04-IMPL

+ (NSString *)probe {
    static S04AddObjCMethod *longLived;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        longLived = [S04AddObjCMethod new];
    });
    return [longLived base]; // S04-CALL
}

@end
