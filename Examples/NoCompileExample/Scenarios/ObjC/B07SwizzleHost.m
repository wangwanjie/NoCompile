//
//  B07SwizzleHost.m
//

#import "B07SwizzleHost.h"
#import <objc/runtime.h>

@implementation B07SwizzleHost

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(work));
    Method hooked = class_getInstanceMethod(self, @selector(b07_hookedWork));
    method_exchangeImplementations(original, hooked);
}

- (NSString *)work {
    return @"work";
}

/// 交换后 -work 执行这里，并通过调用自身 selector 进入原实现
- (NSString *)b07_hookedWork {
    return [NSString stringWithFormat:@"hook(@@v1@@)>%@", [self b07_hookedWork]];
}

+ (NSString *)probe {
    return [[B07SwizzleHost new] work];
}

@end
