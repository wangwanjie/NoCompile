//
//  B06ObjCLoad.m
//  场景 B06：+load / +initialize / __attribute__((constructor))。
//  注入新镜像时这些入口会再次触发，必须不死循环、不崩溃，且不重置 App 里已有的状态
//

#import "B06ObjCLoad.h"

static NSInteger gLoadCalls = 0;
static NSInteger gInitializeCalls = 0;
static NSInteger gConstructorCalls = 0;

__attribute__((constructor))
static void B06Constructor(void) {
    gConstructorCalls += 1;
}

@implementation B06ObjCLoad

+ (void)load {
    gLoadCalls += 1;
}

+ (void)initialize {
    if (self == [B06ObjCLoad class]) {
        gInitializeCalls += 1;
    }
}

+ (NSString *)probe {
    return [NSString stringWithFormat:@"B06(@@v1@@) load=%ld init=%ld ctor=%ld",
            (long)gLoadCalls, (long)gInitializeCalls, (long)gConstructorCalls];
}

@end
