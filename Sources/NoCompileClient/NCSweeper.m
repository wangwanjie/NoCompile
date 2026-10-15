//
//  NCSweeper.m
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCSweeper.h"
#import "NCLog.h"
#import "NoCompile.h"
#include <objc/runtime.h>
#include <objc/message.h>

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define NC_UIKIT 1
#elif __has_include(<AppKit/AppKit.h>)
#import <AppKit/AppKit.h>
#define NC_APPKIT 1
#endif

@implementation NCSweeper

+ (void)performSweepForClasses:(NSArray<Class> *)classes sourceFiles:(NSArray<NSString *> *)sourceFiles {
    dispatch_block_t work = ^{
        [self runOnMainForClasses:classes sourceFiles:sourceFiles];
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

+ (void)runOnMainForClasses:(NSArray<Class> *)classes sourceFiles:(NSArray<NSString *> *)sourceFiles {
    // 1. 对实现了 +injected 的类调用类方法
    SEL injectedSel = @selector(injected);
    NSMutableArray<Class> *instanceInjectedClasses = [NSMutableArray array];
    for (Class cls in classes) {
        Class meta = object_getClass(cls);
        if (class_respondsToSelector(meta, injectedSel)) {
            ((void (*)(id, SEL))objc_msgSend)(cls, injectedSel);
        }
        if (class_respondsToSelector(cls, injectedSel)) {
            [instanceInjectedClasses addObject:cls];
        }
    }

    // 2. 遍历存活实例，对目标类实例调用 -injected
    if (instanceInjectedClasses.count > 0) {
        [self sweepInstancesForClasses:instanceInjectedClasses selector:injectedSel];
    }

    // 3. 自动刷新当前可见、且未实现 -injected 的视图控制器
    if (NoCompile.autoReloadViewControllers) {
        [self reloadVisibleControllersExcludingInjected:instanceInjectedClasses];
    }

    // 4. 发出通知，驱动 SwiftUI / Inject / HotSwiftUI 等刷新
    NSDictionary *userInfo = sourceFiles ? @{ NoCompileInjectedFilesKey: sourceFiles } : @{};
    [NSNotificationCenter.defaultCenter postNotificationName:NoCompileDidInjectNotification
                                                      object:classes userInfo:userInfo];
    [NSNotificationCenter.defaultCenter postNotificationName:NoCompileInjectionBundleNotification
                                                      object:classes userInfo:userInfo];
}

/// 从界面根节点出发，广度遍历对象图，命中目标类实例则回调
+ (void)sweepInstancesForClasses:(NSArray<Class> *)classes selector:(SEL)selector {
    NSArray *seeds = [self sweepSeeds];
    if (seeds.count == 0) {
        return;
    }
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *queue = [seeds mutableCopy];
    NSSet<Class> *targets = [NSSet setWithArray:classes];
    NSUInteger visited = 0;
    const NSUInteger limit = 200000; // 防止对象图过大导致卡顿

    while (queue.count > 0 && visited < limit) {
        id object = queue.lastObject;
        [queue removeLastObject];
        if (!object) {
            continue;
        }
        NSValue *identity = [NSValue valueWithNonretainedObject:object];
        if ([seen containsObject:identity]) {
            continue;
        }
        [seen addObject:identity];
        visited++;

        Class cls = object_getClass(object);
        for (Class target in targets) {
            if ([self class:cls isKindOf:target]) {
                if ([object respondsToSelector:selector]) {
                    ((void (*)(id, SEL))objc_msgSend)(object, selector);
                }
                break;
            }
        }
        [self enqueueChildrenOf:object into:queue];
    }
}

+ (BOOL)class:(Class)cls isKindOf:(Class)target {
    Class current = cls;
    while (current) {
        if (current == target) {
            return YES;
        }
        current = class_getSuperclass(current);
    }
    return NO;
}

/// 收集遍历起点
+ (NSArray *)sweepSeeds {
    NSMutableArray *seeds = [NSMutableArray array];
#if NC_UIKIT
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            [seeds addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    id delegate = UIApplication.sharedApplication.delegate;
    if (delegate) {
        [seeds addObject:delegate];
    }
#elif NC_APPKIT
    [seeds addObjectsFromArray:NSApplication.sharedApplication.windows];
    id delegate = NSApplication.sharedApplication.delegate;
    if (delegate) {
        [seeds addObject:delegate];
    }
#endif
    return seeds;
}

/// 把对象的 ObjC 对象型 ivar 入队
+ (void)enqueueChildrenOf:(id)object into:(NSMutableArray *)queue {
    Class cls = object_getClass(object);
    while (cls && cls != NSObject.class) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id child = object_getIvar(object, ivars[i]);
                if (child) {
                    [queue addObject:child];
                }
            }
        }
        if (ivars) {
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
#if NC_UIKIT
    if ([object isKindOfClass:UIViewController.class]) {
        UIViewController *vc = object;
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.isViewLoaded) {
            [queue addObject:vc.view];
        }
    }
    if ([object isKindOfClass:UIView.class]) {
        [queue addObjectsFromArray:((UIView *)object).subviews];
    }
#endif
}

/// 自动刷新可见 VC：移除并重建视图，适用于未实现 -injected 的控制器
+ (void)reloadVisibleControllersExcludingInjected:(NSArray<Class> *)injectedInstanceClasses {
#if NC_UIKIT
    NSSet<Class> *skip = [NSSet setWithArray:injectedInstanceClasses];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *top = window.rootViewController;
            UIViewController *visible = [self topMostController:top];
            if (visible && ![skip containsObject:visible.class] && visible.isViewLoaded) {
                // 触发重新布局，轻量刷新
                [visible.view setNeedsLayout];
                [visible.view layoutIfNeeded];
            }
        }
    }
#endif
}

#if NC_UIKIT
+ (UIViewController *)topMostController:(UIViewController *)controller {
    if (controller.presentedViewController) {
        return [self topMostController:controller.presentedViewController];
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return [self topMostController:((UINavigationController *)controller).visibleViewController];
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return [self topMostController:((UITabBarController *)controller).selectedViewController];
    }
    return controller;
}
#endif

@end

#endif
