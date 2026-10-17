//
//  ExEventBus.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const ExEventBusDidFire;

/// 通知 + 回调 + 弱引用代理，仿 KuGou 的事件总线
@interface ExEventBus : NSObject

@property (nonatomic, copy, readonly) NSString *lastEvent;

+ (instancetype)shared;
/// 发通知，由 -handleNotification: 处理（观察者在启动时注册，热重载后方法体应立即更新）
- (void)fire:(NSString *)event;

@end

NS_ASSUME_NONNULL_END
