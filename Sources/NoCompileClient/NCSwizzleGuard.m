//
//  NCSwizzleGuard.m
//
//  被注入 dylib 中的 +load 若调用 method_exchangeImplementations，其引用由 dyld 直接绑定到 libobjc，
//  启动时对 App 镜像做的重绑覆盖不到它。因此注册 dyld 的 add-image 回调：
//  该回调在新镜像完成绑定之后、执行初始化（+load）之前触发，此时改写新镜像的符号指针即可生效。
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCSwizzleGuard.h"
#import "NCRebind.h"
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <limits.h>
#include <string.h>
#include <stdatomic.h>

/// 保护区间的重入计数。>0 时拦截 swizzle
static _Atomic(int) gGuardDepth = 0;
/// 正在加载的注入镜像路径（保护区间内有效）
static char gGuardPath[PATH_MAX];

/// 实现地址是否位于正在加载的注入镜像内
static bool NCIMPInGuardedImage(IMP imp) {
    Dl_info info;
    if (!imp || !dladdr((const void *)imp, &info) || !info.dli_fname) {
        return false;
    }
    return strcmp(info.dli_fname, gGuardPath) == 0;
}

/// 替换版 method_exchangeImplementations：保护期内交换一次后，把结果固定为"新实现"，
/// 等价于 +load 中的交换不再改变已存在的 hook 链
static void nc_method_exchangeImplementations(Method m1, Method m2) {
    if (atomic_load(&gGuardDepth) > 0) {
        // 两个实现都在新镜像里：是新镜像里那份类对象对自己的方法做 swizzle，不碰旧类，照常交换；
        // 否则是 +load 去 hook 旧类 / 系统类，首次启动时已经交换过，这里跳过，保持 hook 链不变
        if (!(NCIMPInGuardedImage(method_getImplementation(m1)) && NCIMPInGuardedImage(method_getImplementation(m2)))) {
            return;
        }
    }
    method_exchangeImplementations(m1, m2);
}

static NCRebinding gRebindings[] = {
    { "_method_exchangeImplementations", (void *)nc_method_exchangeImplementations },
};

/// dyld 新增镜像回调：只在保护区间内（即正在 dlopen 注入镜像）处理
static void NCOnImageAdded(const struct mach_header *header, intptr_t slide) {
    if (atomic_load(&gGuardDepth) <= 0 || header->magic != MH_MAGIC_64) {
        return;
    }
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) {
        return;
    }
    NCImage *image = [[NCImage alloc] initWithHeader:(const struct mach_header_64 *)header
                                               slide:slide
                                                path:@(info.dli_fname)];
    NCRebindImage(image, gRebindings, sizeof(gRebindings) / sizeof(gRebindings[0]));
}

void NCSwizzleGuardInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 注册后会对已存在镜像各回调一次，此时不在保护区间，直接忽略
        _dyld_register_func_for_add_image(NCOnImageAdded);
    });
}

void NCSwizzleGuardBegin(const char *path) {
    if (path) {
        strlcpy(gGuardPath, path, sizeof(gGuardPath));
    }
    atomic_fetch_add(&gGuardDepth, 1);
}

void NCSwizzleGuardEnd(void) {
    atomic_fetch_sub(&gGuardDepth, 1);
}

#endif
