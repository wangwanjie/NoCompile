//
//  B15CrossFileCategory+Extra.m
//  场景 B15：宿主类的分类放在另一个文件里，分类方法只在启动时挂到旧类上
//

#import "B15CrossFileCategory+Extra.h"

@implementation B15CrossFileCategory (Extra)

- (NSString *)extraName {
    return @"extra";
}

+ (NSString *)extraClassName {
    return @"extraClass";
}

@end
