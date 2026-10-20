//
//  NCSwizzleGuard.m
//
//  注入的 dylib 被 dlopen 时会执行其中的 +load。+load 若再次 swizzle 已经交换过的方法，hook 链会自我指向、无限递归。
//  因此在加载注入镜像期间拦截 method_exchangeImplementations：
//  1. 启动时把所有 App 镜像（主程序、App 内 framework）对它的引用重绑到包装函数，
//     这样 +load 通过其他文件里的工具方法（如 +[NSObject xx_swizzle:with:]）间接交换时也能拦住；
//  2. 注册 dyld 的 add-image 回调，之后加载的 App 镜像与注入镜像同样重绑。该回调在新镜像完成绑定之后、
//     执行初始化（+load）之前触发，此时改写新镜像的符号指针即可生效。
//  包装函数只在保护区间内、且在执行注入的线程上才起作用，其余时候直接转发，不影响 App 自身的 swizzle。
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
#include <pthread.h>

/// 保护区间的重入计数。>0 时拦截 swizzle
static _Atomic(int) gGuardDepth = 0;
/// 正在加载的注入镜像路径（保护区间内有效）
static char gGuardPath[PATH_MAX];
/// 执行注入的线程（保护区间内有效）：其他线程上的 swizzle 不拦截
static pthread_t gGuardThread;

/// 实现地址是否位于正在加载的注入镜像内
static bool NCIMPInGuardedImage(IMP imp) {
    Dl_info info;
    if (!imp || !dladdr((const void *)imp, &info) || !info.dli_fname) {
        return false;
    }
    return strcmp(info.dli_fname, gGuardPath) == 0;
}

/// libobjc 中真正的 method_exchangeImplementations。包装函数必须经它转发：
/// 客户端静态链入 App 时，客户端自己的符号指针也会被重绑到包装函数，直接调用 method_exchangeImplementations 会无限递归
static void (*gOriginalExchange)(Method, Method) = NULL;

/// 替换版 method_exchangeImplementations：保护期内交换一次后，把结果固定为"新实现"，
/// 等价于 +load 中的交换不再改变已存在的 hook 链
static void nc_method_exchangeImplementations(Method m1, Method m2) {
    if (atomic_load(&gGuardDepth) > 0 && pthread_equal(pthread_self(), gGuardThread)) {
        // 两个实现都在新镜像里：是新镜像里那份类对象对自己的方法做 swizzle，不碰旧类，照常交换；
        // 否则是 +load 去 hook 旧类 / 系统类，首次启动时已经交换过，这里跳过，保持 hook 链不变
        if (!(NCIMPInGuardedImage(method_getImplementation(m1)) && NCIMPInGuardedImage(method_getImplementation(m2)))) {
            return;
        }
    }
    gOriginalExchange(m1, m2);
}

static NCRebinding gRebindings[] = {
    { "_method_exchangeImplementations", (void *)nc_method_exchangeImplementations },
};

/// dyld 新增镜像回调：App 镜像与正在加载的注入镜像都重绑到包装函数，系统库不动
static void NCOnImageAdded(const struct mach_header *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64) {
        return;
    }
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) {
        return;
    }
    BOOL guarded = atomic_load(&gGuardDepth) > 0 && strcmp(info.dli_fname, gGuardPath) == 0;
    if (!guarded && !NCPathIsAppImage(info.dli_fname)) {
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
        // dlsym 返回 libobjc 里的定义，不经过任何镜像的符号指针，重绑之后仍指向真实实现
        gOriginalExchange = (void (*)(Method, Method))dlsym(RTLD_DEFAULT, "method_exchangeImplementations");
        if (!gOriginalExchange) {
            return;
        }
        // 注册后会对已存在的镜像各回调一次，App 镜像在这时完成重绑
        _dyld_register_func_for_add_image(NCOnImageAdded);
    });
}

void NCSwizzleGuardBegin(const char *path) {
    if (path) {
        strlcpy(gGuardPath, path, sizeof(gGuardPath));
    }
    gGuardThread = pthread_self();
    atomic_fetch_add(&gGuardDepth, 1);
}

void NCSwizzleGuardEnd(void) {
    atomic_fetch_sub(&gGuardDepth, 1);
}

#endif
