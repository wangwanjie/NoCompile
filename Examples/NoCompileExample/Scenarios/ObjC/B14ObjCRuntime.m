//
//  B14ObjCRuntime.m
//  场景 B14：运行时动态能力：NSClassFromString / performSelector / associated object / 动态加方法 / 消息转发
//

#import "B14ObjCRuntime.h"
#import <objc/runtime.h>

@interface B14Dynamic : NSObject
- (NSString *)real;
@end

@implementation B14Dynamic

- (NSString *)real {
    return @"real(@@v1@@)";
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    if (sel == NSSelectorFromString(@"dynamicHello")) {
        class_addMethod(self, sel, imp_implementationWithBlock(^NSString *(id _self) {
            return @"dyn";
        }), "@@:");
        return YES;
    }
    return [super resolveInstanceMethod:sel];
}

@end

@implementation B14ObjCRuntime

+ (NSString *)probe {
    Class cls = NSClassFromString(@"B14Dynamic");
    id object = [[cls alloc] init];
    static const void *kKey = &kKey;
    objc_setAssociatedObject(object, kKey, @"assoc", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *real = [object performSelector:@selector(real)];
    NSString *dyn = [object performSelector:NSSelectorFromString(@"dynamicHello")];
#pragma clang diagnostic pop
    return [NSString stringWithFormat:@"%@ %@ %@", real, dyn, objc_getAssociatedObject(object, kKey)];
}

@end
