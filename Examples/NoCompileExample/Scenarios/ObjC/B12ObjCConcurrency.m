//
//  B12ObjCConcurrency.m
//  场景 B12：注入发生时，后台线程正在高频调用被替换的方法 / 锁 / 队列，不能崩溃、不能死锁
//

#import "B12ObjCConcurrency.h"
#include <stdatomic.h>

static NSString *gLastTick = nil;
static _Atomic(long) gTickCount = 0;
static NSLock *gLock;
static dispatch_source_t gTimer;

@implementation B12ObjCConcurrency

+ (void)startTicking {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLock = [[NSLock alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("example.b12.ticker", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, 0);
        dispatch_source_set_event_handler(gTimer, ^{
            NSString *text = [B12ObjCConcurrency tickText];
            [gLock lock];
            gLastTick = text;
            [gLock unlock];
            atomic_fetch_add(&gTickCount, 1);
        });
        dispatch_resume(gTimer);
    });
}

+ (NSString *)tickText {
    return @"B12(@@v1@@)";
}

+ (NSString *)probe {
    [self startTicking];
    [gLock lock];
    NSString *last = gLastTick ?: @"none";
    [gLock unlock];
    return [NSString stringWithFormat:@"%@ ticks=%ld", last, (long)atomic_load(&gTickCount)];
}

@end
