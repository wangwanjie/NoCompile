//
//  H06FrameworkHeaderUser.m
//  场景 H06：引用 framework 公开头文件（ExCore/ExConstants.h）里的枚举。
//  改 framework 头文件后，framework 模块缓存（.pcm）会失效，App 里的使用方重编不能因此失败
//

#import <ExCore/ExCore.h>
#import "H06FrameworkHeaderUser.h"

@implementation H06FrameworkHeaderUser

+ (NSString *)probe {
    ExPoint point = ExPointMake(1, 2);
    return [NSString stringWithFormat:@"H06 shuffle=%ld name=%@ tag=%d", (long)ExPlayModeShuffle, ExPlayModeName(ExPlayModeShuffle), point.tag];
}

@end
