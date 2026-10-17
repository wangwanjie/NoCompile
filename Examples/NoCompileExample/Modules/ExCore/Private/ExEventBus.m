//
//  ExEventBus.m
//  场景 B12：启动时注册的通知观察者，其处理方法在热重载后应使用新实现
//

#import <ExCore/ExEventBus.h>

NSNotificationName const ExEventBusDidFire = @"ExEventBusDidFire";

@interface ExEventBus ()
@property (nonatomic, copy, readwrite) NSString *lastEvent;
@end

@implementation ExEventBus

+ (instancetype)shared {
    static ExEventBus *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ExEventBus alloc] init];
        instance.lastEvent = @"";
        [[NSNotificationCenter defaultCenter] addObserver:instance
                                                 selector:@selector(handleNotification:)
                                                     name:ExEventBusDidFire
                                                   object:nil];
    });
    return instance;
}

- (void)fire:(NSString *)event {
    [[NSNotificationCenter defaultCenter] postNotificationName:ExEventBusDidFire object:event];
}

- (void)handleNotification:(NSNotification *)note {
    self.lastEvent = [NSString stringWithFormat:@"%@|ExEventBus:@@v1@@", note.object];
}

@end
