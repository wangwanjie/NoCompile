//
//  ExSwizzleTarget.m
//  场景 B07：+load 里做 method_exchangeImplementations。
//  修改本文件会注入新镜像并重新执行 +load：若不拦截，交换会被再做一次而还原，hook 链被破坏。
//

#import <ExCore/ExSwizzleTarget.h>
#import <objc/runtime.h>

static NSInteger gLoadCount = 0;

@implementation ExSwizzleTarget

+ (void)load {
    gLoadCount += 1;
    Method original = class_getInstanceMethod(self, @selector(describe));
    Method hooked = class_getInstanceMethod(self, @selector(ex_hookedDescribe));
    method_exchangeImplementations(original, hooked);
}

+ (NSInteger)loadCount {
    return gLoadCount;
}

- (NSString *)describe {
    return @"original";
}

/// 交换后，调用 -describe 实际执行这里；这里的 ex_hookedDescribe 调用原实现
- (NSString *)ex_hookedDescribe {
    return [NSString stringWithFormat:@"hooked(@@v1@@)->%@", [self ex_hookedDescribe]];
}

@end
