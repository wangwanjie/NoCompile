//
//  NCSwizzleGuard.m
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCSwizzleGuard.h"
#import "NCRebind.h"
#include <objc/runtime.h>
#include <stdatomic.h>

/// 保护区间的重入计数。>0 时拦截 swizzle
static _Atomic(int) gGuardDepth = 0;

// 原始实现指针
static IMP (*gOrigExchange)(Method, Method);
static IMP (*gOrigSetImp)(Method, IMP);

/// 替换版：method_exchangeImplementations。保护期内退化为两次 setImplementation（幂等）
static void nc_method_exchangeImplementations(Method m1, Method m2) {
    if (atomic_load(&gGuardDepth) > 0) {
        IMP imp1 = method_getImplementation(m1);
        IMP imp2 = method_getImplementation(m2);
        method_setImplementation(m1, imp2);
        method_setImplementation(m2, imp1);
        return;
    }
    method_exchangeImplementations(m1, m2);
}

void NCSwizzleGuardInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gOrigExchange = (void *)&method_exchangeImplementations;
        NCRebinding rebindings[] = {
            { "_method_exchangeImplementations", (void *)nc_method_exchangeImplementations },
        };
        NCRebindAllAppImages(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    });
}

void NCSwizzleGuardBegin(void) {
    atomic_fetch_add(&gGuardDepth, 1);
}

void NCSwizzleGuardEnd(void) {
    atomic_fetch_sub(&gGuardDepth, 1);
}

#endif
