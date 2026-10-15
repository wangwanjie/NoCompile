//
//  NCInjector.m
//  进程内注入核心
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
#include <objc/message.h>
#include <string.h>

@implementation NCInjectResult
@end

/// 判断一个 Swift / C++ 符号是否可被 interpose 替换。
/// 规则参考 SwiftTrace.injectableSymbol：按 mangled 名后缀识别函数类实体。
static BOOL NCInjectableSymbol(const char *name, BOOL preserveStatics) {
    if (!name || name[0] != '_') {
        return NO;
    }
    name++; // 跳过前导下划线

    // C++ 成员函数 / 自由函数（Itanium ABI）
    if (strncmp(name, "_ZN", 3) == 0 || strncmp(name, "_Z", 2) == 0) {
        return YES;
    }
    // 仅处理 Swift 符号（$s / $S 开头）
    if (!(name[0] == '$' && (name[1] == 's' || name[1] == 'S'))) {
        return NO;
    }
    // 排除标准库符号（第三个字符为 S/s 多为 stdlib）
    if (name[2] == 'S' || name[2] == 's') {
        return NO;
    }
    size_t len = strlen(name);
    if (len < 2) {
        return NO;
    }
    const char *tail = name + len;
    #define NC_ENDS(suffix) (len >= strlen(suffix) && strcmp(tail - strlen(suffix), suffix) == 0)

    // 函数 / 静态函数（排除 MF：元数据相关）
    if (NC_ENDS("F") && !NC_ENDS("MF")) {
        return YES;
    }
    if (NC_ENDS("fD")) {              // 析构函数
        return YES;
    }
    // getter / setter / modify / read 访问器
    if (NC_ENDS("vg") || NC_ENDS("vs") || NC_ENDS("vM") || NC_ENDS("vr")) {
        return YES;
    }
    // 全局 / 静态变量的可变寻址器
    if (NC_ENDS("vau")) {
        return !preserveStatics;      // 需要保留静态状态时不替换，改为反向绑定
    }
    #undef NC_ENDS
    return NO;
}

/// 判断符号是否是全局 / 静态变量寻址器（保留静态状态用）
static BOOL NCIsStaticAddressor(const char *name) {
    if (!name) {
        return NO;
    }
    size_t len = strlen(name);
    return len >= 3 && strcmp(name + len - 3, "vau") == 0;
}

/// 用 objc runtime 找出与新类同名的所有旧类（主程序及历史注入镜像中可能有多份）
static NSArray<Class> *NCOldClassesNamed(const char *className, Class excluding) {
    NSMutableArray<Class> *result = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (cls == excluding) {
            continue;
        }
        if (strcmp(class_getName(cls), className) == 0) {
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
        IMP imp = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        class_replaceMethod(oldClass, sel, imp, types);
        replaced++;
    }
    free(methods);
    return replaced;
}

/// Swift vtable 覆写：把 newMeta 的 vtable 槽位复制进 oldMeta。
/// 返回替换的槽位数；若两边槽位数不一致（增删方法 / 改布局）返回 -1 表示拒绝
static long NCPatchSwiftVTable(Class oldClass, Class newClass) {
    NCSwiftClassMetadata *oldMeta = (__bridge NCSwiftClassMetadata *)oldClass;
    NCSwiftClassMetadata *newMeta = (__bridge NCSwiftClassMetadata *)newClass;
    if (!NCIsSwiftClass(oldClass) || !NCIsSwiftClass(newClass)) {
        return 0;
    }
    if (oldMeta->classSize != newMeta->classSize) {
        return -1; // 布局变化，vtable 尺寸不同
    }
    long slots = NCSwiftVTableSlotCount(oldMeta);
    NCSwiftImpl *oldVTable = NCSwiftVTable(oldMeta);
    NCSwiftImpl *newVTable = NCSwiftVTable(newMeta);
    long patched = 0;
    for (long i = 0; i < slots; i++) {
        if (newVTable[i] && oldVTable[i] != newVTable[i]) {
            NCSwiftImpl *slot = &oldVTable[i];
            NCSwiftImpl value = newVTable[i];
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
    dispatch_sync([self injectionQueue], ^{
        result = [self performInject:dylibPath sourceFiles:sourceFiles];
    });
    return result;
}

+ (NCInjectResult *)performInject:(NSString *)dylibPath sourceFiles:(NSArray<NSString *> *)sourceFiles {
    NCInjectResult *result = [NCInjectResult new];

    // dlopen 期间拦截 +load 中的 swizzling，避免 hook 链自我指向导致死循环
    BOOL guard = NoCompile.suppressSwizzlingDuringLoad;
    if (guard) {
        NCSwizzleGuardBegin();
    }
    void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (guard) {
        NCSwizzleGuardEnd();
    }
    if (!handle) {
        result.status = NCInjectStatusLoadFailed;
        const char *err = dlerror();
        result.message = [self explainLoadError:err ? @(err) : @"dlopen 失败"];
        return result;
    }

    NCImage *newImage = NCImageForPath(dylibPath);
    if (!newImage) {
        result.status = NCInjectStatusLoadFailed;
        result.message = @"dylib 已加载但无法在镜像列表中定位";
        return result;
    }
    NCRegisterInjectedImagePath(dylibPath);

    BOOL preserveStatics = NoCompile.preserveStaticState;

    // 1. 收集新镜像中的类符号与可注入函数符号
    NSMutableArray<NSString *> *newClassSymbols = [NSMutableArray array];
    NSMutableArray *interposeNames = [NSMutableArray array];   // NSString
    NSMutableArray *interposeImpls = [NSMutableArray array];   // NSValue(pointer)
    NSMutableArray *staticAddressorNames = [NSMutableArray array];

    NCEnumerateSymbols(newImage, ^(const char *name, uintptr_t address, uint8_t type,
                                   const struct section_64 *section, BOOL *stop) {
        if (address == 0) {
            return;
        }
        size_t len = strlen(name);
        // Swift 类元数据符号：_$s...CN
        if (len > 3 && strcmp(name + len - 2, "CN") == 0 && strncmp(name, "_$s", 3) == 0) {
            [newClassSymbols addObject:@(name)];
        }
        // ObjC 类符号：_OBJC_CLASS_$_
        if (strncmp(name, "_OBJC_CLASS_$_", 14) == 0) {
            [newClassSymbols addObject:@(name)];
        }
        if (NCInjectableSymbol(name, preserveStatics)) {
            [interposeNames addObject:@(name)];
            [interposeImpls addObject:[NSValue valueWithPointer:(void *)address]];
        }
        if (preserveStatics && NCIsStaticAddressor(name)) {
            [staticAddressorNames addObject:@(name)];
        }
    });

    // 2. 定位新类对象并替换 ObjC / Swift 实现
    NSMutableArray<Class> *injectedClasses = [NSMutableArray array];
    NSUInteger objcReplaced = 0;
    long swiftPatched = 0;
    BOOL layoutChanged = NO;

    for (NSString *symbol in newClassSymbols) {
        Class newClass = [self classForSymbol:symbol handle:handle];
        if (!newClass) {
            continue;
        }
        const char *className = class_getName(newClass);
        NSArray<Class> *oldClasses = NCOldClassesNamed(className, newClass);
        if (oldClasses.count == 0) {
            // 新增类，无需嫁接
            [injectedClasses addObject:newClass];
            continue;
        }
        for (Class oldClass in oldClasses) {
            long patched = NCPatchSwiftVTable(oldClass, newClass);
            if (patched < 0) {
                layoutChanged = YES;
                continue;
            }
            swiftPatched += patched;
            // ObjC 方法（实例方法 + 类方法）
            objcReplaced += NCSwizzleObjCMethods(oldClass, newClass);
            objcReplaced += NCSwizzleObjCMethods(object_getClass(oldClass), object_getClass(newClass));
            [self fixDynamicCastFrom:newClass to:oldClass];
        }
        [injectedClasses addObject:newClass];
    }

    // 3. 函数级 interpose：改写所有 App 镜像里对这些符号的调用
    NSUInteger reboundTotal = 0;
    NSUInteger count = interposeNames.count;
    if (count > 0) {
        NCRebinding *rebindings = calloc(count, sizeof(NCRebinding));
        for (NSUInteger i = 0; i < count; i++) {
            rebindings[i].name = [interposeNames[i] UTF8String];
            rebindings[i].replacement = [interposeImpls[i] pointerValue];
        }
        reboundTotal = NCRebindAllAppImages(rebindings, count);
        free(rebindings);
    }

    // 4. 保留静态 / 全局状态：把新镜像里的寻址器指回旧实现
    if (preserveStatics && staticAddressorNames.count > 0) {
        [self preserveStaticsFor:staticAddressorNames newImage:newImage];
    }

    if (layoutChanged && objcReplaced == 0 && swiftPatched == 0) {
        result.status = NCInjectStatusLayoutChanged;
        result.message = @"检测到内存布局变化（疑似增删了存储属性或方法），已拒绝注入以避免崩溃";
        return result;
    }
    if (objcReplaced == 0 && swiftPatched == 0 && reboundTotal == 0) {
        result.status = NCInjectStatusNothingInjected;
        result.message = @"未替换任何实现。请确认 Debug 配置的 Other Linker Flags 含 -Xlinker -interposable";
        return result;
    }

    result.status = NCInjectStatusSuccess;
    result.objcMethodsReplaced = objcReplaced;
    result.swiftSlotsPatched = swiftPatched;
    result.symbolsRebound = reboundTotal;
    result.injectedClasses = injectedClasses;

    // 5. 回主线程：调用 injected() 回调、遍历实例、发出通知
    [NCSweeper performSweepForClasses:injectedClasses sourceFiles:sourceFiles];
    return result;
}

/// 从符号名解析出对应的类对象
+ (Class)classForSymbol:(NSString *)symbol handle:(void *)handle {
    const char *name = symbol.UTF8String;
    // dlsym 需要去掉前导下划线
    void *ptr = dlsym(handle, name + 1);
    if (!ptr) {
        return nil;
    }
    if ([symbol hasPrefix:@"_OBJC_CLASS_$_"]) {
        return (__bridge Class)ptr;
    }
    // Swift 类元数据符号指向 metadata，即 Class 本身
    return (__bridge Class)ptr;
}

/// 修复 as? / isKindOfClass 判定：被注入后新旧类不是同一个对象
+ (void)fixDynamicCastFrom:(Class)newClass to:(Class)oldClass {
    // 交给 NCDynamicCast 模块统一登记（实现见 NCDynamicCast.m）
    extern void NCRegisterClassAlias(Class newClass, Class oldClass);
    NCRegisterClassAlias(newClass, oldClass);
}

/// 把新镜像中的静态变量寻址器重绑回旧实现，保留原有状态
+ (void)preserveStaticsFor:(NSArray<NSString *> *)names newImage:(NCImage *)newImage {
    NSUInteger count = names.count;
    NCRebinding *rebindings = calloc(count, sizeof(NCRebinding));
    NSUInteger valid = 0;
    for (NSUInteger i = 0; i < count; i++) {
        const char *name = [names[i] UTF8String];
        void *oldImpl = dlsym(RTLD_DEFAULT, name + 1); // 旧实现仍在主程序中
        if (oldImpl) {
            rebindings[valid].name = name;
            rebindings[valid].replacement = oldImpl;
            valid++;
        }
    }
    if (valid > 0) {
        NCRebindImage(newImage, rebindings, valid);
    }
    free(rebindings);
}

/// 把 dlopen 的底层错误翻译成可读的中文提示
+ (NSString *)explainLoadError:(NSString *)raw {
    if ([raw containsString:@"symbol not found"] || [raw containsString:@"Symbol not found"]) {
        return [NSString stringWithFormat:@"加载失败：存在未解析符号（常见于默认参数或私有符号未导出）。\n%@", raw];
    }
    if ([raw containsString:@"code signature"]) {
        return [NSString stringWithFormat:@"加载失败：签名无效。真机需使用与 App 一致的开发者身份签名 dylib。\n%@", raw];
    }
    if ([raw containsString:@"__llvm_profile"]) {
        return [NSString stringWithFormat:@"加载失败：代码覆盖率符号缺失。链接 dylib 时需加 -fprofile-instr-generate。\n%@", raw];
    }
    return raw;
}

@end

#endif
