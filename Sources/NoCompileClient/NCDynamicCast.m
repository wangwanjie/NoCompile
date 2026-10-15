//
//  NCDynamicCast.m
//  类型判定修复
//
//  被注入后，dylib 内 [Foo new] 得到的是"新 Foo"，App 其余代码持有的是"旧 Foo"，
//  两者不是同一个 Class 对象。这会让 isKindOfClass: / isMemberOfClass: 以及 Swift 的
//  as? 判定失败。这里登记新旧类的等价关系，并改写判定逻辑使其按"原始类"比较。
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <objc/message.h>

@interface NCDynamicCastInstaller : NSObject
+ (void)install;
@end

/// 新类 → 原始（最初的）类 的映射
static NSMapTable<Class, Class> *NCAliasMap(void) {
    static NSMapTable *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaquePersonality | NSPointerFunctionsOpaqueMemory
                                    valueOptions:NSPointerFunctionsOpaquePersonality | NSPointerFunctionsOpaqueMemory];
    });
    return map;
}

/// 把某个类归一到它的"原始类"：顺着别名链一直回溯
static Class NCCanonicalClass(Class cls) {
    Class result = cls;
    @synchronized (NCAliasMap()) {
        Class mapped = [NCAliasMap() objectForKey:result];
        while (mapped) {
            result = mapped;
            mapped = [NCAliasMap() objectForKey:result];
        }
    }
    return result;
}

void NCRegisterClassAlias(Class newClass, Class oldClass) {
    if (!newClass || !oldClass || newClass == oldClass) {
        return;
    }
    @synchronized (NCAliasMap()) {
        // 记录到"旧类的原始类"，保证多次注入后仍指向最初的类
        [NCAliasMap() setObject:NCCanonicalClass(oldClass) forKey:newClass];
    }
    [NCDynamicCastInstaller install];
}

@implementation NCDynamicCastInstaller

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self swizzleInstance:@selector(isKindOfClass:) with:@selector(nc_isKindOfClass:)];
        [self swizzleInstance:@selector(isMemberOfClass:) with:@selector(nc_isMemberOfClass:)];
    });
}

+ (void)swizzleInstance:(SEL)original with:(SEL)replacement {
    Class cls = NSObject.class;
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(self, replacement);
    if (!originalMethod || !replacementMethod) {
        return;
    }
    IMP replacementImp = method_getImplementation(replacementMethod);
    const char *types = method_getTypeEncoding(originalMethod);
    // 把替换实现加到 NSObject 上
    class_replaceMethod(cls, original, replacementImp, types);
}

// 下面两个方法会以 NSObject 实例方法的身份被调用，self 为被判定对象

- (BOOL)nc_isKindOfClass:(Class)aClass {
    Class selfCanonical = NCCanonicalClass(object_getClass(self));
    Class targetCanonical = NCCanonicalClass(aClass);
    Class current = selfCanonical;
    while (current) {
        if (current == targetCanonical) {
            return YES;
        }
        current = class_getSuperclass(current);
    }
    return NO;
}

- (BOOL)nc_isMemberOfClass:(Class)aClass {
    return NCCanonicalClass(object_getClass(self)) == NCCanonicalClass(aClass);
}

@end

#endif
