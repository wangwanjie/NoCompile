//
//  ExMediator.m
//

#import <ExCore/ExMediator.h>
#import <objc/message.h>

@implementation ExMediator

+ (instancetype)shared {
    static ExMediator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ExMediator alloc] init];
    });
    return instance;
}

- (id)performTarget:(NSString *)target action:(NSString *)action params:(NSDictionary *)params {
    Class targetClass = NSClassFromString([NSString stringWithFormat:@"Target_%@", target]);
    if (targetClass == Nil) {
        return nil;
    }
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"Action_%@:", action]);
    id instance = [[targetClass alloc] init];
    if (![instance respondsToSelector:selector]) {
        return nil;
    }
    // 与 CTMediator 一致：用 objc_msgSend 直接调用，避免 performSelector 的 ARC 警告
    return ((id (*)(id, SEL, id))objc_msgSend)(instance, selector, params);
}

@end
