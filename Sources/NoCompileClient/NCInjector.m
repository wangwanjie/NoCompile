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
#import "NCStaticState.h"
#import "NCSweeper.h"
#import "NCLog.h"
#import "NoCompile.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <string.h>

@implementation NCInjectResult
@end

/// 历次注入中每个符号的最新实现：后注入的 dylib 引用到这些符号时，要指向最新实现而不是 App 里的原始版本
/// （dyld 按符号表解析，App 镜像导出的永远是第一次编译进去的旧代码）
static NSMutableDictionary<NSString *, NSValue *> *NCLatestSymbolImpls(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSMutableDictionary dictionary];
    });
    return table;
}

extern void NCRegisterClassAlias(Class newClass, Class oldClass);

static BOOL NCHasSuffix(const char *name, size_t len, const char *suffix) {
    size_t suffixLen = strlen(suffix);
    return len >= suffixLen && strcmp(name + len - suffixLen, suffix) == 0;
}

/// 符号是否由 Swift 运行时 / 标准库镜像提供（这类符号不能被 App 的注入替换）
static BOOL NCIsStdlibSymbol(const char *name) {
    void *address = dlsym(RTLD_DEFAULT, name + 1);
    if (!address) {
        return NO;
    }
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) {
        return NO;
    }
    return strstr(info.dli_fname, "libswift") != NULL;
}

/// 外部只读数据符号是否可整体替换：位于只读数据节（__DATA_CONST / __const）的 C 命名常量。
/// C++ vtable / typeinfo、ObjC 元数据、Swift 元数据不处理
static BOOL NCIsReplaceableConstantData(const char *name, const struct section_64 *section) {
    if (!name || name[0] != '_') {
        return NO;
    }
    const char *body = name + 1;
    if (strncmp(body, "_Z", 2) == 0 || strncmp(body, "OBJC_", 5) == 0 || strncmp(body, "$s", 2) == 0
        || strncmp(body, "_OBJC", 5) == 0 || strncmp(body, "swift", 5) == 0 || strncmp(body, "_swift", 6) == 0) {
        return NO;
    }
    BOOL readOnlySegment = strncmp(section->segname, "__DATA_CONST", 16) == 0;
    BOOL constSection = strncmp(section->sectname, "__const", 16) == 0;
    if (!readOnlySegment && !constSection) {
        return NO;
    }
    return YES;
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
        // 以 $sS / $ss 开头的符号可能是标准库自己的，也可能是 App 给标准库类型 / ObjC 类型（$sSo 开头，
        // 如 UIView、UIColor）写的扩展方法。后者很常见，不能一律排除：
        // 只有同名符号确实由 Swift 标准库镜像提供时才跳过
        if ((body[2] == 'S' || body[2] == 's') && NCIsStdlibSymbol(name)) {
            return NO;
        }
        // static 成员在 mangled 名末尾多一个 Z（如 static func → FZ，static var getter → vgZ），先去掉再判断
        size_t effectiveLen = len;
        if (effectiveLen > 1 && body[effectiveLen - 1] == 'Z') {
            effectiveLen--;
        }
        char tail[4] = {0};
        size_t tailLen = effectiveLen < 3 ? effectiveLen : 3;
        memcpy(tail, body + effectiveLen - tailLen, tailLen);
        size_t tl = strlen(tail);
        if (NCHasSuffix(tail, tl, "F") && !NCHasSuffix(tail, tl, "MF")) {
            return YES;                 // 函数 / 方法 / 静态方法
        }
        if (NCHasSuffix(tail, tl, "fD") || NCHasSuffix(tail, tl, "fC")) {
            return YES;                 // 析构 / 构造
        }
        if (NCHasSuffix(tail, tl, "vg") || NCHasSuffix(tail, tl, "vs") ||
            NCHasSuffix(tail, tl, "vM") || NCHasSuffix(tail, tl, "vr")) {
            return YES;                 // 属性访问器（含 static）
        }
        if (NCHasSuffix(tail, tl, "vau")) {
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
    // 全局变量为 vau，static 存储属性为 vauZ
    return strncmp(name, "_$s", 3) == 0 && (NCHasSuffix(name, len, "vau") || NCHasSuffix(name, len, "vauZ"));
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

/// ObjC 类的实例变量布局是否发生变化（个数、名字、偏移或类型任一不同）。
/// Swift 类不在这里判断（它们的存储属性变化由元数据大小比较处理）
static BOOL NCObjCIvarLayoutChanged(Class oldClass, Class newClass) {
    if (NCIsSwiftClass(oldClass) || NCIsSwiftClass(newClass)) {
        return NO;
    }
    if (class_getInstanceSize(oldClass) == class_getInstanceSize(newClass)) {
        // 大小相同时仍可能重排，下面逐个比较
    }
    unsigned int oldCount = 0, newCount = 0;
    Ivar *oldIvars = class_copyIvarList(oldClass, &oldCount);
    Ivar *newIvars = class_copyIvarList(newClass, &newCount);
    BOOL changed = oldCount != newCount;
    for (unsigned int i = 0; !changed && i < oldCount; i++) {
        const char *oldName = ivar_getName(oldIvars[i]);
        const char *newName = ivar_getName(newIvars[i]);
        const char *oldType = ivar_getTypeEncoding(oldIvars[i]);
        const char *newType = ivar_getTypeEncoding(newIvars[i]);
        if (!oldName || !newName || strcmp(oldName, newName) != 0 || ivar_getOffset(oldIvars[i]) != ivar_getOffset(newIvars[i])
            || (oldType && newType && strcmp(oldType, newType) != 0)) {
            changed = YES;
        }
    }
    free(oldIvars);
    free(newIvars);
    return changed;
}

/// 方法实现所在函数的符号名（如 `-[Foo bar]`）。Debug 产物保留了局部符号，取不到时返回 nil
static NSString *NCFunctionNameForIMP(IMP imp) {
    Dl_info info;
    if (imp && dladdr((const void *)imp, &info) && info.dli_sname && info.dli_sname[0] != '\0') {
        return @(info.dli_sname);
    }
    return nil;
}

/// ObjC 方法替换：把 newClass 的方法逐个写回 oldClass。
///
/// 按"函数体"而不是按选择子配对：旧类的方法可能被 method_exchangeImplementations 换过（+load 里的 swizzle），
/// 此时选择子 `work` 指向的是 `-[Foo hookedWork]` 的函数体。直接按选择子替换会把交换还原，hook 链被破坏。
/// 所以先按函数符号名找到旧类里当前指向该函数体的选择子，把新函数体写到那个选择子上，交换关系得以保留。
/// 找不到对应函数体（新增方法、符号被剥离、block 实现）时退回按选择子替换。
static NSUInteger NCSwizzleObjCMethods(Class oldClass, Class newClass) {
    NSUInteger replaced = 0;

    unsigned int oldCount = 0;
    Method *oldMethods = class_copyMethodList(oldClass, &oldCount);
    NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *selectorsByFunction = [NSMutableDictionary dictionary];
    for (unsigned int i = 0; i < oldCount; i++) {
        NSString *function = NCFunctionNameForIMP(method_getImplementation(oldMethods[i]));
        if (!function) {
            continue;
        }
        NSMutableArray<NSValue *> *selectors = selectorsByFunction[function];
        if (!selectors) {
            selectors = [NSMutableArray array];
            selectorsByFunction[function] = selectors;
        }
        [selectors addObject:[NSValue valueWithPointer:method_getName(oldMethods[i])]];
    }
    free(oldMethods);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(newClass, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        // +load / +initialize 不回写，避免改变旧类的初始化语义
        if (sel == @selector(load) || sel == @selector(initialize)) {
            continue;
        }
        IMP imp = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        NSString *function = NCFunctionNameForIMP(imp);
        NSArray<NSValue *> *targets = function ? selectorsByFunction[function] : nil;
        if (targets.count > 0) {
            for (NSValue *target in targets) {
                class_replaceMethod(oldClass, (SEL)target.pointerValue, imp, types);
                replaced++;
            }
            continue;
        }
        class_replaceMethod(oldClass, sel, imp, types);
        replaced++;
    }
    free(methods);
    return replaced;
}

/// 把旧类里新类没有的方法补到新类上。
///
/// dylib 内部的 `[Foo alloc]`、`[Foo new]` 引用的是新镜像自己的那份类对象，创建出来的实例属于"新类"。
/// 而 App 里其他文件定义的分类（如 `Foo+QA.m`）在启动时只挂在旧类上，新类并没有这些方法，
/// 新类的实例收到这类消息就会 unrecognized selector 崩溃。这里把旧类当前的方法补到新类（已有同名方法的不覆盖，
/// 新类自己的实现优先），实例方法和类方法都处理。
static NSUInteger NCInheritMissingMethods(Class oldClass, Class newClass) {
    NSUInteger added = 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(oldClass, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel == @selector(load) || sel == @selector(initialize)) {
            continue;
        }
        // class_addMethod 只在新类自身没有该方法时才添加，不会覆盖新类的实现
        if (class_addMethod(newClass, sel, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]))) {
            added++;
        }
    }
    free(methods);
    return added;
}

/// ObjC 分类在磁盘上的头部布局（与 objc4 的 category_t 前两个字段一致），这里只读取宿主类
typedef struct {
    const char *name;
    Class cls;
} NCCategoryHeader;

/// 统计新镜像里的分类，并收集它们的宿主类。
///
/// 只含分类的文件（如 UIViewController+Xxx.m）没有 _OBJC_CLASS_$_ 符号，也没有可改写的函数符号。
/// 但 dlopen 时 ObjC 运行时已把新分类的方法列表挂到宿主类方法列表的最前面，同名方法会先于旧分类命中，
/// 改动即时生效，因此这类注入应算成功，不能报"未替换任何实现"。
/// 宿主类定义在新镜像自身时（类与分类写在同一文件），由类方法替换流程处理，这里不收集。
static NSUInteger NCCollectCategories(NCImage *image, NSMutableArray<Class> *hostClasses) {
    size_t size = 0;
    void *data = NCSectionData(image, NULL, "__objc_catlist", &size);
    if (!data || size == 0) {
        return 0;
    }
    NSUInteger attached = 0;
    NCCategoryHeader **list = (NCCategoryHeader **)data;
    size_t count = size / sizeof(NCCategoryHeader *);
    for (size_t i = 0; i < count; i++) {
        NCCategoryHeader *category = list[i];
        // 宿主类为弱引用且缺失时为空
        if (!category || !category->cls) {
            continue;
        }
        attached++;
        const char *hostImage = class_getImageName(category->cls);
        BOOL definedInNewImage = hostImage && strcmp(hostImage, image.path.fileSystemRepresentation) == 0;
        if (!definedInNewImage && ![hostClasses containsObject:category->cls]) {
            [hostClasses addObject:category->cls];
        }
    }
    return attached;
}

/// Swift vtable 覆写。返回替换的槽位数（>=0）。
///
/// outLayoutChanged 置为 YES 表示新旧 classSize 或 classAddressPoint 不一致，即发生了
/// vtable 布局变化（增删/重排方法）。这种情况下**不覆写**：旧实例仍指向旧元数据，其
/// vtable 槽位数是旧的；Debug（-Onone）下方法一律走 vtable 静态派发，若覆写后的旧方法体
/// 调用了新增方法，会按新槽位下标访问越界而崩溃。因此布局变化时跳过 vtable，仅加载新代码，
/// 由调用方提示重新运行；新增/删方法只对重新运行后、走新元数据的实例生效。
///
/// 布局未变（仅改方法体）时按下标逐个覆写，立即在既有实例上生效。
static long NCPatchSwiftVTable(Class oldClass, Class newClass, BOOL *outLayoutChanged) {
    if (outLayoutChanged) {
        *outLayoutChanged = NO;
    }
    if (!NCIsSwiftClass(oldClass) || !NCIsSwiftClass(newClass)) {
        return 0;
    }
    NCSwiftClassMetadata *oldMeta = (__bridge NCSwiftClassMetadata *)oldClass;
    NCSwiftClassMetadata *newMeta = (__bridge NCSwiftClassMetadata *)newClass;
    if (oldMeta->classSize != newMeta->classSize ||
        oldMeta->classAddressPoint != newMeta->classAddressPoint) {
        if (outLayoutChanged) {
            *outLayoutChanged = YES;
        }
        return 0;
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
    return [self injectDylibAtPath:dylibPath sourceFiles:sourceFiles isNewFile:NO];
}

+ (NCInjectResult *)injectDylibAtPath:(NSString *)dylibPath
                          sourceFiles:(NSArray<NSString *> *)sourceFiles
                            isNewFile:(BOOL)isNewFile {
    __block NCInjectResult *result = nil;
    // 串行化多次注入；实际替换在主线程执行，避免与 UI 代码并发
    dispatch_sync([self injectionQueue], ^{
        if (NSThread.isMainThread) {
            result = [self performInject:dylibPath sourceFiles:sourceFiles isNewFile:isNewFile];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                result = [self performInject:dylibPath sourceFiles:sourceFiles isNewFile:isNewFile];
            });
        }
    });
    return result;
}

+ (NCInjectResult *)performInject:(NSString *)dylibPath sourceFiles:(NSArray<NSString *> *)sourceFiles isNewFile:(BOOL)isNewFile {
    NCInjectResult *result = [NCInjectResult new];

    // dlopen 会执行新镜像的 +load；加载期间拦截其中的 swizzling，避免 hook 链自我指向
    BOOL guard = NoCompile.suppressSwizzlingDuringLoad;
    if (guard) {
        NCSwizzleGuardBegin(dylibPath.fileSystemRepresentation);
    }
    // 新增文件的符号在 App 中不存在，之后的注入（如引用了新类型的旧文件）要靠全局查找链接到它
    void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW | (isNewFile ? RTLD_GLOBAL : RTLD_LOCAL));
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
    NSMutableSet<NSString *> *weakDefinedNames = [NSMutableSet set];
    NSMutableArray<NSString *> *undefinedNames = [NSMutableArray array];

    NCEnumerateSymbolsWithDesc(newImage, ^(const char *name, uintptr_t address, uint8_t type, uint16_t desc,
                                           const struct section_64 *section, BOOL *stop) {
        if (address == 0 && (type & N_TYPE) == N_UNDF) {
            [undefinedNames addObject:@(name)];
            return;
        }
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
        // 外部只读数据（`NSString *const kTitle`、`const int kLimit`、const 数组 / 结构体）：
        // 其他镜像里的引用要指向新值，否则旧文件读到的仍是旧常量
        if ((type & N_EXT) && NCIsReplaceableConstantData(name, section)) {
            [interposeNames addObject:@(name)];
            [interposeImpls addObject:[NSValue valueWithPointer:(void *)address]];
            return;
        }
        BOOL isText = strncmp(section->sectname, "__text", 16) == 0;
        if (!isText) {
            return;
        }
        if (NCInjectableSymbol(name, type, preserveStatics)) {
            [interposeNames addObject:@(name)];
            [interposeImpls addObject:[NSValue valueWithPointer:(void *)address]];
            // 弱定义（C++ 模板 / inline 函数等）：dyld 的弱符号合并会让新镜像自己的引用也绑到旧镜像的那份，
            // 新镜像内部同样需要改写，否则新代码调用到的 inline / 模板函数仍是旧实现
            if (desc & N_WEAK_DEF) {
                [weakDefinedNames addObject:@(name)];
            }
        }
        if (preserveStatics && NCIsStaticAddressor(name)) {
            [staticAddressors addObject:@(name)];
        }
    });

    // 2. ObjC 方法替换与 Swift vtable 覆写
    NSMutableArray<Class> *patchedClasses = [NSMutableArray array];
    NSMutableArray<Class> *addedClasses = [NSMutableArray array];
    NSUInteger objcReplaced = 0;
    NSUInteger ivarLayoutSkipped = 0;
    long swiftPatched = 0;
    // 发生布局变化（增删方法或存储属性）的类名：既不覆写其 vtable，也不在其旧实例上重跑生命周期
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
            // ObjC 类的 ivar 布局变了（新增 / 删除 / 重排 @property 的实例变量）：旧实例按旧大小分配，
            // 新方法体按新偏移读写 ivar 会越过对象末尾、破坏堆内存。此时不替换这个类的方法，
            // 只提示重新运行 App
            if (NCObjCIvarLayoutChanged(oldClass, newClass)) {
                if (![layoutChanged containsObject:@(className)]) {
                    [layoutChanged addObject:@(className)];
                }
                ivarLayoutSkipped++;
                continue;
            }
            // 布局变化（增删方法改变 vtable，或增删存储属性改变实例大小）时不再拒绝注入，但也不能
            // 动旧实例：旧元数据的 vtable 槽位数、实例大小都已固定，覆写或重跑生命周期都会越界崩溃。
            // 这里只加载新代码、登记类别名、并替换 ObjC/@objc 方法（动态派发，增删方法是安全的）。
            // 纯 Swift 的增删方法/属性要重新运行 App 后、由走新元数据的新实例体现。
            BOOL vtableLayoutChanged = NO;
            long patched = NCPatchSwiftVTable(oldClass, newClass, &vtableLayoutChanged);
            BOOL sizeChanged = class_getInstanceSize(oldClass) != class_getInstanceSize(newClass);
            if (vtableLayoutChanged || sizeChanged) {
                if (![layoutChanged containsObject:@(className)]) {
                    [layoutChanged addObject:@(className)];
                }
            }
            swiftPatched += patched;
            // ObjC / @objc 方法：动态派发，新增或改写都能即时安全生效
            objcReplaced += NCSwizzleObjCMethods(oldClass, newClass);
            objcReplaced += NCSwizzleObjCMethods(object_getClass(oldClass), object_getClass(newClass));
            // 新类的实例（dylib 内 alloc 出来的）也要能响应旧类上由其他文件的分类等提供的方法
            NCInheritMissingMethods(oldClass, newClass);
            NCInheritMissingMethods(object_getClass(oldClass), object_getClass(newClass));
            NCRegisterClassAlias(newClass, oldClass);
            if (![patchedClasses containsObject:oldClass]) {
                [patchedClasses addObject:oldClass];
            }
        }
    }

    // 2.5 分类：运行时在 dlopen 时已把它们附加到宿主类。App 自有类的宿主纳入受影响类，用于提示重进页面；
    //     系统类（如 UIViewController）不纳入，否则几乎所有控制器都会被判定为受影响
    NSMutableArray<Class> *categoryHosts = [NSMutableArray array];
    NSUInteger categoriesAttached = NCCollectCategories(newImage, categoryHosts);
    for (Class host in categoryHosts) {
        if ([NCSweeper isAppClass:host] && ![patchedClasses containsObject:host]) {
            [patchedClasses addObject:host];
        }
    }

    // 2.8 新增的符号（App 里没有同名定义，如新增 / 改了签名的函数）：提升为全局，
    //     之后注入的 dylib 才能引用到它们（否则 dlopen 报未解析符号）
    if (!isNewFile) {
        NSUInteger newSymbols = 0;
        for (NSString *name in interposeNames) {
            if (!dlsym(RTLD_DEFAULT, name.UTF8String + 1)) {
                newSymbols++;
            }
        }
        if (newSymbols > 0) {
            dlopen(dylibPath.fileSystemRepresentation, RTLD_NOLOAD | RTLD_GLOBAL);
        }
    }

    // 2.9 新镜像引用了此前注入过的符号：指向它们的最新实现
    NSMutableDictionary<NSString *, NSValue *> *latest = NCLatestSymbolImpls();
    NSMutableSet<NSString *> *definedHere = [NSMutableSet setWithArray:interposeNames];
    if (latest.count > 0 && undefinedNames.count > 0) {
        NSMutableArray<NSString *> *wanted = [NSMutableArray array];
        for (NSString *name in undefinedNames) {
            if (latest[name] && ![definedHere containsObject:name]) {
                [wanted addObject:name];
            }
        }
        if (wanted.count > 0) {
            NCRebinding *refs = calloc(wanted.count, sizeof(NCRebinding));
            for (NSUInteger i = 0; i < wanted.count; i++) {
                refs[i].name = wanted[i].UTF8String;
                refs[i].replacement = latest[wanted[i]].pointerValue;
            }
            NCRebindImage(newImage, refs, wanted.count);
            free(refs);
        }
    }
    for (NSUInteger i = 0; i < interposeNames.count; i++) {
        latest[interposeNames[i]] = interposeImpls[i];
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
            // 新镜像内部对自身（强）函数的调用无需改写
            if (image.header == newImage.header) {
                continue;
            }
            rebound += NCRebindImage(image, rebindings, count);
        }
        // 新镜像内部：只改写弱定义符号的引用，让它们指向新镜像自己的那份
        if (weakDefinedNames.count > 0) {
            NCRebinding *weakRebindings = calloc(weakDefinedNames.count, sizeof(NCRebinding));
            NSUInteger weakCount = 0;
            for (NSUInteger i = 0; i < count; i++) {
                if ([weakDefinedNames containsObject:interposeNames[i]]) {
                    weakRebindings[weakCount].name = rebindings[i].name;
                    weakRebindings[weakCount].replacement = rebindings[i].replacement;
                    weakCount++;
                }
            }
            NCRebindImage(newImage, weakRebindings, weakCount);
            free(weakRebindings);
        }
        free(rebindings);
    }

    // 4. 保留静态状态：新镜像里的全局 / 静态变量寻址器指回旧实现，单例不会被重建
    if (preserveStatics && staticAddressors.count > 0) {
        [self rebindStaticAddressors:staticAddressors inImage:newImage];
    }
    // 4.5 C / ObjC 的 static 变量（`static dispatch_once_t`、`static Foo *instance`、文件内计数器等）：
    //     新镜像自带一份存储，不迁移的话单例会被重建、计数清零
    if (preserveStatics) {
        NSUInteger moved = NCTransferStaticState(newImage, NCAppImages(), sourceFiles);
        if (moved > 0) {
            NCLogInfo(@"已迁移 %lu 个 static 变量的状态", (unsigned long)moved);
        }
    }

    // dylib 只定义了 App 里没有的新符号（新增函数、改了签名的函数）时同样算成功：它们靠后续注入引用
    BOOL definesOnlyNewSymbols = NO;
    if (interposeNames.count > 0 && rebound == 0) {
        definesOnlyNewSymbols = YES;
        for (NSString *name in interposeNames) {
            void *existing = dlsym(RTLD_DEFAULT, name.UTF8String + 1);
            // 全局提升后 dlsym 能找到新镜像自己的符号：用地址区分是否是新镜像的
            if (existing && !NCImageContainsAddress(newImage, existing)) {
                definesOnlyNewSymbols = NO;
                break;
            }
        }
    }
    if (objcReplaced == 0 && swiftPatched == 0 && rebound == 0 && categoriesAttached == 0 && addedClasses.count == 0 && !isNewFile
        && ivarLayoutSkipped == 0 && !definesOnlyNewSymbols) {
        result.status = NCInjectStatusNothingInjected;
        result.message = @"未替换任何实现。请确认 Debug 配置的 Other Linker Flags 含 -Xlinker -interposable";
        return result;
    }
    if (ivarLayoutSkipped > 0) {
        NCLogWarn(@"%@ 的实例变量布局变了（新增 / 调整了带 ivar 的 @property 或成员变量）：旧实例按旧大小分配，直接替换方法会越界破坏内存，已跳过这些类的方法替换，请重新运行 App",
                  [layoutChanged componentsJoinedByString:@", "]);
    } else if (layoutChanged.count > 0) {
        // 布局已变化：新代码已加载，ObjC/@objc 方法的增改已即时生效；纯 Swift 的增删方法/属性
        // 需重新运行 App 后由新实例体现。已在屏幕上的旧实例保持原样，不在其上刷新以免越界
        NCLogWarn(@"%@ 增删了方法或存储属性：新代码已加载，ObjC/@objc 方法即时生效；纯 Swift 的增删需重新运行 App 才会在新实例上体现（屏幕上的旧实例保持原样）",
                  [layoutChanged componentsJoinedByString:@", "]);
    }

    result.status = NCInjectStatusSuccess;
    result.objcMethodsReplaced = objcReplaced;
    result.swiftSlotsPatched = (NSUInteger)swiftPatched;
    result.symbolsRebound = rebound;
    result.categoriesAttached = categoriesAttached;
    result.layoutChangedClasses = [layoutChanged copy];
    result.injectedClasses = [patchedClasses arrayByAddingObjectsFromArray:addedClasses];

    // 5. 处理受影响的可见界面，并发出通知（当前已在主线程）
    NSArray<NSString *> *pending = nil;
    result.refreshedControllers = [NCSweeper refreshAfterPatchingClasses:patchedClasses
                                                            addedClasses:addedClasses
                                                     layoutChangedClasses:[NSSet setWithArray:layoutChanged]
                                                             sourceFiles:sourceFiles
                                                      pendingControllers:&pending];
    result.pendingControllers = pending ?: @[];
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
        // RTLD_DEFAULT 按加载顺序查找：普通文件找到 App 中的旧实现；
        // 新增文件在 App 中没有该符号，会找到它第一次注入时（RTLD_GLOBAL）的镜像，同样保留了状态
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
