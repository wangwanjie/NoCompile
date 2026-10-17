//
//  S05AddObjCProperty.m
//  场景 S05：给 ObjC 类增加属性（ivar 布局变化）。旧实例分配时按旧大小，新代码访问新 ivar 会越界，
//  客户端必须避免这种情况（不崩溃）
//

#import "S05AddObjCProperty.h"

@implementation S05AddObjCProperty

+ (NSString *)probe {
    static S05AddObjCProperty *longLived;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        longLived = [S05AddObjCProperty new];
        longLived.name = @"S05-name";
    });
    return longLived.name; // S05-USE
}

@end
