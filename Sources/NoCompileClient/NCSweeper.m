//
//  NCSweeper.m
//  注入后的零侵入刷新
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
typedef UIViewController NCViewController;
typedef UIView NCView;
#elif __has_include(<AppKit/AppKit.h>)
#import <AppKit/AppKit.h>
#define NC_APPKIT 1
typedef NSViewController NCViewController;
typedef NSView NCView;
#endif

@implementation NCSweeper

+ (NSArray<NSString *> *)refreshAfterPatchingClasses:(NSArray<Class> *)patchedClasses
                                        addedClasses:(NSArray<Class> *)addedClasses
                                         sourceFiles:(NSArray<NSString *> *)sourceFiles {
    // 以类名作为匹配依据：App 中的实例属于旧类，dylib 中的是新类，二者名字相同
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (Class cls in patchedClasses) {
        [names addObject:@(class_getName(cls))];
    }

    NSMutableArray<NSString *> *refreshed = [NSMutableArray array];

    // 1. 兼容项：+injected
    SEL injectedSel = NSSelectorFromString(@"injected");
    for (Class cls in patchedClasses) {
        if (class_respondsToSelector(object_getClass(cls), injectedSel)) {
            ((void (*)(id, SEL))objc_msgSend)(cls, injectedSel);
        }
    }

#if NC_UIKIT || NC_APPKIT
    // 2. 默认：零侵入刷新受影响的可见视图控制器
    if (NoCompile.autoReloadViewControllers) {
        [refreshed addObjectsFromArray:[self reloadAffectedControllersForClassNames:names]];
    }
#endif

    // 3. 通知：供 SwiftUI 或其他需要自定义刷新的场景使用
    NSMutableArray *all = [patchedClasses mutableCopy];
    [all addObjectsFromArray:addedClasses];
    NSDictionary *userInfo = sourceFiles ? @{ NoCompileInjectedFilesKey: sourceFiles } : @{};
    [NSNotificationCenter.defaultCenter postNotificationName:NoCompileDidInjectNotification
                                                      object:all userInfo:userInfo];
    [NSNotificationCenter.defaultCenter postNotificationName:NoCompileInjectionBundleNotification
                                                      object:all userInfo:userInfo];
    return refreshed;
}

#pragma mark - 类名匹配

/// 判断类（含父类链）是否命中被替换的类名
+ (BOOL)classChain:(Class)cls hitsNames:(NSSet<NSString *> *)names {
    Class current = cls;
    while (current) {
        if ([names containsObject:@(class_getName(current))]) {
            return YES;
        }
        current = class_getSuperclass(current);
    }
    return NO;
}

/// 判断类是否属于 App 自身（排除系统框架中的容器控制器等）
+ (BOOL)isAppClass:(Class)cls {
    const char *image = class_getImageName(cls);
    if (!image) {
        return NO;
    }
    return strncmp(image, "/System/", 8) != 0
        && strncmp(image, "/usr/lib/", 9) != 0
        && strstr(image, "/Developer/Library/") == NULL
        && strstr(image, "/Library/Developer/CoreSimulator/Volumes/") == NULL
        && strstr(image, ".simruntime/") == NULL;
}

#if NC_UIKIT || NC_APPKIT

#pragma mark - 可见控制器收集

+ (NSArray<NCViewController *> *)rootControllers {
    NSMutableArray<NCViewController *> *roots = [NSMutableArray array];
#if NC_UIKIT
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.rootViewController) {
                [roots addObject:window.rootViewController];
            }
        }
    }
#else
    for (NSWindow *window in NSApplication.sharedApplication.windows) {
        if (window.isVisible && window.contentViewController) {
            [roots addObject:window.contentViewController];
        }
    }
#endif
    return roots;
}

/// 从根控制器出发收集当前可见的控制器（含容器与其可见子控制器）
+ (void)collectVisibleFrom:(NCViewController *)controller into:(NSMutableArray<NCViewController *> *)result {
    if (!controller || [result containsObject:controller]) {
        return;
    }
    [result addObject:controller];
#if NC_UIKIT
    if ([controller isKindOfClass:UINavigationController.class]) {
        [self collectVisibleFrom:((UINavigationController *)controller).topViewController into:result];
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        [self collectVisibleFrom:((UITabBarController *)controller).selectedViewController into:result];
    } else {
        for (UIViewController *child in controller.childViewControllers) {
            [self collectVisibleFrom:child into:result];
        }
    }
    [self collectVisibleFrom:controller.presentedViewController into:result];
#else
    for (NSViewController *child in controller.childViewControllers) {
        [self collectVisibleFrom:child into:result];
    }
    for (NSViewController *presented in controller.presentedViewControllers) {
        [self collectVisibleFrom:presented into:result];
    }
#endif
}

/// 控制器自身视图层级中（不含子控制器的视图）是否有被替换的视图类
+ (BOOL)controller:(NCViewController *)controller ownsViewHittingNames:(NSSet<NSString *> *)names {
    if (!controller.isViewLoaded) {
        return NO;
    }
    NSMutableSet<NCView *> *childRoots = [NSMutableSet set];
    for (NCViewController *child in controller.childViewControllers) {
        if (child.isViewLoaded) {
            [childRoots addObject:child.view];
        }
    }
    NSMutableArray<NCView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    while (stack.count > 0) {
        NCView *view = stack.lastObject;
        [stack removeLastObject];
        if ([self classChain:view.class hitsNames:names]) {
            return YES;
        }
        for (NCView *sub in view.subviews) {
            if (![childRoots containsObject:sub]) {
                [stack addObject:sub];
            }
        }
    }
    return NO;
}

#pragma mark - 刷新

+ (NSArray<NSString *> *)reloadAffectedControllersForClassNames:(NSSet<NSString *> *)names {
    NSMutableArray<NCViewController *> *visible = [NSMutableArray array];
    for (NCViewController *root in [self rootControllers]) {
        [self collectVisibleFrom:root into:visible];
    }

    // 只处理 App 自己的控制器，系统容器（导航、标签栏等）不重建
    NSMutableArray<NCViewController *> *targets = [NSMutableArray array];
    for (NCViewController *controller in visible) {
        if (![self isAppClass:controller.class]) {
            continue;
        }
        if ([self classChain:controller.class hitsNames:names] ||
            [self controller:controller ownsViewHittingNames:names]) {
            [targets addObject:controller];
        }
    }

    // 被替换的是模型、工具类、C/C++ 函数等非界面代码：刷新最上层的可见业务控制器，让新逻辑立即体现
    if (targets.count == 0) {
        for (NCViewController *controller in visible.reverseObjectEnumerator) {
            if ([self isAppClass:controller.class] && controller.isViewLoaded) {
                [targets addObject:controller];
                break;
            }
        }
    }

    // 父控制器重建时会重新创建子控制器，子控制器无需单独处理
    NSMutableArray<NCViewController *> *finalTargets = [NSMutableArray array];
    for (NCViewController *controller in targets) {
        BOOL ancestorIncluded = NO;
        NCViewController *parent = controller.parentViewController;
        while (parent) {
            if ([targets containsObject:parent]) {
                ancestorIncluded = YES;
                break;
            }
            parent = parent.parentViewController;
        }
        if (!ancestorIncluded) {
            [finalTargets addObject:controller];
        }
    }

    NSMutableArray<NSString *> *refreshed = [NSMutableArray array];
    SEL injectedSel = NSSelectorFromString(@"injected");
    for (NCViewController *controller in finalTargets) {
        NSString *name = NSStringFromClass(controller.class);
        if ([controller respondsToSelector:injectedSel]) {
            // 兼容项：业务方自定义了刷新逻辑
            ((void (*)(id, SEL))objc_msgSend)(controller, injectedSel);
        } else {
            [self reloadController:controller];
        }
        [refreshed addObject:[name componentsSeparatedByString:@"."].lastObject];
    }
    return refreshed;
}

/// 判断类是否重写了 -loadView（自定义根视图的控制器需要重新 loadView）
+ (BOOL)overridesLoadView:(Class)cls {
    SEL sel = @selector(loadView);
    IMP own = class_getMethodImplementation(cls, sel);
    IMP base = class_getMethodImplementation([NCViewController class], sel);
    return own != base;
}

/// 重建一个控制器的界面
+ (void)reloadController:(NCViewController *)controller {
    if (!controller.isViewLoaded) {
        return;
    }
    NCView *oldView = controller.view;

#if NC_UIKIT
    // 列表类控制器：根视图本身是 table / collection，重载数据即可
    if ([oldView isKindOfClass:UITableView.class]) {
        [(UITableView *)oldView reloadData];
        return;
    }
    if ([oldView isKindOfClass:UICollectionView.class]) {
        [(UICollectionView *)oldView reloadData];
        return;
    }
#endif

    // 移除子控制器（viewDidLoad 会重新添加）
    for (NCViewController *child in controller.childViewControllers.copy) {
#if NC_UIKIT
        [child willMoveToParentViewController:nil];
        [child.view removeFromSuperview];
        [child removeFromParentViewController];
#else
        [child.view removeFromSuperview];
        [child removeFromParentViewController];
#endif
    }

    if ([self overridesLoadView:controller.class]) {
        // 自定义根视图：重新 loadView，并把新视图放回原位置
        [self replaceRootViewOf:controller oldView:oldView];
    } else {
        for (NCView *sub in oldView.subviews.copy) {
            [sub removeFromSuperview];
        }
    }

    // 重新走一遍生命周期
#if NC_UIKIT
    [controller viewDidLoad];
    [controller viewWillAppear:NO];
    [controller.view setNeedsLayout];
    [controller.view layoutIfNeeded];
    [controller viewDidAppear:NO];
#else
    [controller viewDidLoad];
    [controller viewWillAppear];
    controller.view.needsLayout = YES;
    [controller.view layoutSubtreeIfNeeded];
    [controller viewDidAppear];
#endif
}

+ (void)replaceRootViewOf:(NCViewController *)controller oldView:(NCView *)oldView {
#if NC_UIKIT
    UIView *superview = oldView.superview;
    CGRect frame = oldView.frame;
    UIViewAutoresizing mask = oldView.autoresizingMask;
    [controller loadView];
    UIView *newView = controller.view;
    if (newView == oldView) {
        return;
    }
    newView.frame = frame;
    newView.autoresizingMask = mask;
    if (superview) {
        [superview insertSubview:newView aboveSubview:oldView];
        [oldView removeFromSuperview];
    }
#else
    NSWindow *window = oldView.window;
    BOOL isContentView = window && window.contentView == oldView;
    NSView *superview = oldView.superview;
    NSRect frame = oldView.frame;
    NSAutoresizingMaskOptions mask = oldView.autoresizingMask;
    [controller loadView];
    NSView *newView = controller.view;
    if (newView == oldView) {
        return;
    }
    if (isContentView) {
        window.contentView = newView;
    } else if (superview) {
        newView.frame = frame;
        newView.autoresizingMask = mask;
        [superview addSubview:newView positioned:NSWindowAbove relativeTo:oldView];
        [oldView removeFromSuperview];
    }
#endif
}

#endif

@end

#endif
