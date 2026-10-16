//
//  NCInjector.m
//  进程内注入核心
//
//  三层替换：
//  1. ObjC：把新类的方法逐个 class_replaceMethod 回旧类
//  2. Swift 类：把新类元数据的 vtable 槽位复制进旧类元数据
//  3. 函数级：C / C++ / Swift 静态派发函数，改写 App 镜像中的符号指针（需 -interposable）
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCInjector.h"
#import "NCMachO.h"
#import "NCRebind.h"
#import "NCSwiftMetadata.h"
#import "NCSwizzleGuard.h"
#import "NCSweeper.h"
#import "NCLog.h"
#import "NoCompile.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <string.h>

@implementation NCInjectResult
@end

extern void NCRegisterClassAlias(Class newClass, Class oldClass);

static BOOL NCHasSuffix(const char *name, size_t len, const char *suffix) {
    size_t suffixLen = strlen(suffix);
    return len >= suffixLen && strcmp(name + len - suffixLen, suffix) == 0;
}

/// 判断一个已定义在 __text 节中的符号是否可被函数级替换
static BOOL NCInjectableSymbol(const char *name, uint8_t type, BOOL preserveStatics) {
    if (!name || name[0] != '_') {
        return NO;
    }
    const char *body = name + 1; // 跳过前导下划线
    size_t len = strlen(body);

    // Swift 符号：按 mangled 名后缀识别函数类实体（参考 SwiftTrace.injectableSymbol）
    if (body[0] == '$' && (body[1] == 's' || body[1] == 'S')) {
        // 标准库符号（$sS / $ss）不处理
        if (body[2] == 'S' || body[2] == 's') {
            return NO;
        }
        if (NCHasSuffix(body, len, "F") && !NCHasSuffix(body, len, "MF")) {
            return YES;                 // 函数 / 方法 / 静态方法
        }
        if (NCHasSuffix(body, len, "fD") || NCHasSuffix(body, len, "fC")) {
            return YES;                 // 析构 / 构造
        }
        if (NCHasSuffix(body, len, "vg") || NCHasSuffix(body, len, "vs") ||
            NCHasSuffix(body, len, "vM") || NCHasSuffix(body, len, "vr")) {
            return YES;                 // 属性访问器
        }
        if (NCHasSuffix(body, len, "vau")) {
            return !preserveStatics;    // 全局 / 静态变量寻址器
        }
        return NO;
    }
    // C++（Itanium ABI）：排除全局构造等编译器生成的初始化函数
    if (strncmp(body, "_Z", 2) == 0) {
        return strstr(body, "GLOBAL__sub_I") == NULL;
    }
    // ObjC 运行时元数据不处理
    if (strncmp(body, "OBJC_", 5) == 0 || strncmp(body, "objc_", 5) == 0) {
        return NO;
    }
    // C 函数：只处理外部可见的符号；入口函数与编译器生成的符号不处理
    if (!(type & N_EXT)) {
        return NO;
    }
    if (strcmp(body, "main") == 0 || body[0] == '_' || body[0] == '.') {
        return NO;
    }
    return YES;
}

/// 全局 / 静态变量寻址器（保留静态状态时反向绑定回旧实现）
static BOOL NCIsStaticAddressor(const char *name) {
    size_t len = strlen(name);
    return strncmp(name, "_$s", 3) == 0 && NCHasSuffix(name, len, "vau");
}

/// 找出与新类同名的所有旧类（主程序及历史注入镜像中可能各有一份）
static NSArray<Class> *NCOldClassesNamed(const char *className, Class excluding) {
    NSMutableArray<Class> *result = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (cls != excluding && strcmp(class_getName(cls), className) == 0) {
            [result addObject:cls];
        }
    }
    free(classes);
    return result;
}

/// ObjC 方法替换：把 newClass 的方法逐个写回 oldClass
static NSUInteger NCSwizzleObjCMethods(Class oldClass, Class newClass) {
    NSUInteger replaced = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(newClass, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        // +load / +initialize 不回写，避免改变旧类的初始化语义
        if (sel == @selector(load) || sel == @selector(initialize)) {
            continue;
        }
        class_replaceMethod(oldClass, sel, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
        replaced++;
    }
    free(methods);
    return replaced;
}

/// Swift vtable 覆写。返回替换的槽位数；布局不一致返回 -1
static long NCPatchSwiftVTable(Class oldClass, Class newClass) {
    if (!NCIsSwiftClass(oldClass) || !NCIsSwiftClass(newClass)) {
        return 0;
    }
    NCSwiftClassMetadata *oldMeta = (__bridge NCSwiftClassMetadata *)oldClass;
    NCSwiftClassMetadata *newMeta = (__bridge NCSwiftClassMetadata *)newClass;
    if (oldMeta->classSize != newMeta->classSize || oldMeta->classAddressPoint != newMeta->classAddressPoint) {
        return -1;
    }
    long slots = NCSwiftVTableSlotCount(oldMeta);
    NCSwiftImpl *oldVTable = NCSwiftVTable(oldMeta);
    NCSwiftImpl *newVTable = NCSwiftVTable(newMeta);
    long patched = 0;
    for (long i = 0; i < slots; i++) {
        NCSwiftImpl value = newVTable[i];
        if (value && oldVTable[i] != value) {
            NCSwiftImpl *slot = &oldVTable[i];
            NCWithWritableMemory(slot, sizeof(NCSwiftImpl), ^{
                *slot = value;
            });
            patched++;
        }
    }
    return patched;
}

@implementation NCInjector

+ (dispatch_queue_t)injectionQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.nocompile.injection", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (NCInjectResult *)injectDylibAtPath:(NSString *)dylibPath sourceFiles:(NSArray<NSString *> *)sourceFiles {
    __block NCInjectResult *result = nil;
    // 串行化多次注入；实际替换在主线程执行，避免与 UI 代码并发
    dispatch_sync([self injectionQueue], ^{
        if (NSThread.isMainThread) {
            result = [self performInject:dylibPath sourceFiles:sourceFiles];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                result = [self performInject:dylibPath sourceFiles:sourceFiles];
            });
        }
    });
    return result;
}

+ (NCInjectResult *)performInject:(NSString *)dylibPath sourceFiles:(NSArray<NSString *> *)sourceFiles {
    NCInjectResult *result = [NCInjectResult new];

    // dlopen 会执行新镜像的 +load；加载期间拦截其中的 swizzling，避免 hook 链自我指向
    BOOL guard = NoCompile.suppressSwizzlingDuringLoad;
    if (guard) {
        NCSwizzleGuardBegin();
    }
    void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (guard) {
        NCSwizzleGuardEnd();
    }
    if (!handle) {
        const char *err = dlerror();
        result.status = NCInjectStatusLoadFailed;
        result.message = [self explainLoadError:err ? @(err) : @"dlopen 失败"];
        return result;
    }

    NCImage *newImage = NCImageForPath(dylibPath);
    if (!newImage) {
        result.status = NCInjectStatusLoadFailed;
        result.message = @"dylib 已加载但无法在镜像列表中定位";
        return result;
    }
    NCRegisterInjectedImagePath(newImage.path);

    BOOL preserveStatics = NoCompile.preserveStaticState;

    // 1. 收集新镜像中的类符号与可替换的函数符号
    NSMutableArray<NSString *> *classSymbols = [NSMutableArray array];
    NSMutableArray<NSString *> *interposeNames = [NSMutableArray array];
    NSMutableArray<NSValue *> *interposeImpls = [NSMutableArray array];
    NSMutableArray<NSString *> *staticAddressors = [NSMutableArray array];

    NCEnumerateSymbols(newImage, ^(const char *name, uintptr_t address, uint8_t type,
                                   const struct section_64 *section, BOOL *stop) {
        if (address == 0 || !section) {
            return;
        }
        size_t len = strlen(name);
        if (strncmp(name, "_OBJC_CLASS_$_", 14) == 0) {
            [classSymbols addObject:@(name)];
            return;
        }
        // Swift 类元数据（ObjC 兼容类在 __objc_classlist 中也会出现，这里用 CN 统一取）
        if (strncmp(name, "_$s", 3) == 0 && NCHasSuffix(name, len, "CN")) {
            [classSymbols addObject:@(name)];
            return;
        }
        BOOL isText = strncmp(section->sectname, "__text", 16) == 0;
        if (!isText) {
            return;
        }
        if (NCInjectableSymbol(name, type, preserveStatics)) {
            [interposeNames addObject:@(name)];
            [interposeImpls addObject:[NSValue valueWithPointer:(void *)address]];
        }
        if (preserveStatics && NCIsStaticAddressor(name)) {
            [staticAddressors addObject:@(name)];
        }
    });

    // 2. ObjC 方法替换与 Swift vtable 覆写
    NSMutableArray<Class> *patchedClasses = [NSMutableArray array];
    NSMutableArray<Class> *addedClasses = [NSMutableArray array];
    NSUInteger objcReplaced = 0;
    long swiftPatched = 0;
    NSMutableArray<NSString *> *layoutChanged = [NSMutableArray array];

    for (NSString *symbol in classSymbols) {
        void *ptr = [self classPointerForSymbol:symbol handle:handle];
        if (!ptr) {
            continue;
        }
        Class newClass = (__bridge Class)ptr;
        const char *className = class_getName(newClass);
        NSArray<Class> *oldClasses = NCOldClassesNamed(className, newClass);
        if (oldClasses.count == 0) {
            [addedClasses addObject:newClass];
            continue;
        }
        for (Class oldClass in oldClasses) {
            long patched = NCPatchSwiftVTable(oldClass, newClass);
            if (patched < 0) {
                [layoutChanged addObject:@(className)];
                continue;
            }
            if (class_getInstanceSize(oldClass) != class_getInstanceSize(newClass)) {
                NCLogWarn(@"%s 的实例大小发生变化（增删了存储属性），已有对象访问新属性可能异常，建议重新运行", className);
            }
            swiftPatched += patched;
            objcReplaced += NCSwizzleObjCMethods(oldClass, newClass);
            objcReplaced += NCSwizzleObjCMethods(object_getClass(oldClass), object_getClass(newClass));
            NCRegisterClassAlias(newClass, oldClass);
            if (![patchedClasses containsObject:oldClass]) {
                [patchedClasses addObject:oldClass];
            }
        }
    }

    // 3. 函数级替换：改写所有 App 镜像（含历史注入镜像）里对这些符号的引用
    NSUInteger rebound = 0;
    NSUInteger count = interposeNames.count;
    if (count > 0) {
        NCRebinding *rebindings = calloc(count, sizeof(NCRebinding));
        for (NSUInteger i = 0; i < count; i++) {
            rebindings[i].name = interposeNames[i].UTF8String;
            rebindings[i].replacement = interposeImpls[i].pointerValue;
        }
        for (NCImage *image in NCAppImages()) {
            // 新镜像内部对自身函数的调用无需改写
            if (image.header == newImage.header) {
                continue;
            }
            rebound += NCRebindImage(image, rebindings, count);
        }
        free(rebindings);
    }

    // 4. 保留静态状态：新镜像里的全局 / 静态变量寻址器指回旧实现，单例不会被重建
    if (preserveStatics && staticAddressors.count > 0) {
        [self rebindStaticAddressors:staticAddressors inImage:newImage];
    }

    if (layoutChanged.count > 0 && objcReplaced == 0 && swiftPatched == 0 && rebound == 0) {
        result.status = NCInjectStatusLayoutChanged;
        result.message = [NSString stringWithFormat:@"%@ 的方法表布局发生变化（增删了方法或存储属性），为避免崩溃已跳过，请重新运行 App",
                          [layoutChanged componentsJoinedByString:@", "]];
        return result;
    }
    if (objcReplaced == 0 && swiftPatched == 0 && rebound == 0 && addedClasses.count == 0) {
        result.status = NCInjectStatusNothingInjected;
        result.message = @"未替换任何实现。请确认 Debug 配置的 Other Linker Flags 含 -Xlinker -interposable";
        return result;
    }
    if (layoutChanged.count > 0) {
        NCLogWarn(@"%@ 的方法表布局变化，这些类的 Swift 方法未更新，请重新运行 App",
                  [layoutChanged componentsJoinedByString:@", "]);
    }

    result.status = NCInjectStatusSuccess;
    result.objcMethodsReplaced = objcReplaced;
    result.swiftSlotsPatched = (NSUInteger)swiftPatched;
    result.symbolsRebound = rebound;
    result.injectedClasses = [patchedClasses arrayByAddingObjectsFromArray:addedClasses];

    // 5. 零侵入刷新可见界面，并发出通知（当前已在主线程）
    result.refreshedControllers = [NCSweeper refreshAfterPatchingClasses:patchedClasses
                                                            addedClasses:addedClasses
                                                             sourceFiles:sourceFiles];
    return result;
}

/// 取类对象。Swift 类优先调用元数据访问器（...CMa），确保需要运行时初始化的元数据已初始化
+ (void *)classPointerForSymbol:(NSString *)symbol handle:(void *)handle {
    // dlsym 需要去掉前导下划线
    NSString *name = [symbol substringFromIndex:1];
    if ([name hasPrefix:@"$s"] && [name hasSuffix:@"CN"]) {
        NSString *accessorName = [[name substringToIndex:name.length - 2] stringByAppendingString:@"CMa"];
        void *accessor = dlsym(handle, accessorName.UTF8String);
        if (accessor) {
            // MetadataResponse accessor(MetadataRequest)：请求 0 表示完整元数据，返回值首字段即元数据指针
            typedef void *(*NCMetadataAccessor)(size_t request);
            void *metadata = ((NCMetadataAccessor)accessor)(0);
            if (metadata) {
                return metadata;
            }
        }
    }
    return dlsym(handle, name.UTF8String);
}

/// 把新镜像中的静态变量寻址器重绑回旧实现，保留原有状态
+ (void)rebindStaticAddressors:(NSArray<NSString *> *)names inImage:(NCImage *)image {
    NSUInteger count = names.count;
    NCRebinding *rebindings = calloc(count, sizeof(NCRebinding));
    NSUInteger valid = 0;
    for (NSUInteger i = 0; i < count; i++) {
        const char *name = names[i].UTF8String;
        // 新镜像以 RTLD_LOCAL 打开，RTLD_DEFAULT 只会找到 App 中的旧实现
        void *oldImpl = dlsym(RTLD_DEFAULT, name + 1);
        if (oldImpl) {
            rebindings[valid].name = name;
            rebindings[valid].replacement = oldImpl;
            valid++;
        }
    }
    if (valid > 0) {
        NCRebindImage(image, rebindings, valid);
    }
    free(rebindings);
}

/// 把 dlopen 的底层错误翻译成可读的中文提示
+ (NSString *)explainLoadError:(NSString *)raw {
    if ([raw containsString:@"symbol not found"] || [raw containsString:@"Symbol not found"]) {
        return [NSString stringWithFormat:@"加载失败：存在未解析符号（常见于 private/fileprivate 符号或默认参数）。\n%@", raw];
    }
    if ([raw containsString:@"code signature"] || [raw containsString:@"not valid for use in process"]) {
        return [NSString stringWithFormat:@"加载失败：签名无效。真机需与 App 使用同一开发团队的身份签名。\n%@", raw];
    }
    if ([raw containsString:@"__llvm_profile"]) {
        return [NSString stringWithFormat:@"加载失败：代码覆盖率符号缺失。\n%@", raw];
    }
    return raw;
}

@end

#endif
