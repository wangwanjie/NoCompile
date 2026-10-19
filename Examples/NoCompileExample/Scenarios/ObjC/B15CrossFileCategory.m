//
//  B15CrossFileCategory.m
//  场景 B15（宿主类部分）：宿主类在本文件内 new 出自己的实例，
//  再调用定义在另一个文件分类里的方法。改动本文件后，dylib 内 new 出来的是"新类"的实例，
//  新类必须也能响应其他文件分类提供的方法，否则 unrecognized selector 崩溃
//

#import "B15CrossFileCategory.h"
#import "B15CrossFileCategory+Extra.h"

@implementation B15CrossFileCategory

- (NSString *)hostName {
    return @"host(@@v1@@)";
}

+ (NSString *)probe {
    B15CrossFileCategory *host = [B15CrossFileCategory new];
    return [NSString stringWithFormat:@"%@ %@ %@", [host hostName], [host extraName], [B15CrossFileCategory extraClassName]];
}

@end
