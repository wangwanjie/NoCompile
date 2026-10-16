//
//  NCResources.m
//  资源热重载：storyboard / xib 编译产物与图片
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCResources.h"
#import "NCSweeper.h"
#import "NCLog.h"
#import "NoCompile.h"
#include <objc/runtime.h>
#include <objc/message.h>

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define NC_UIKIT 1
typedef UIImage NCPlatformImage;
#elif __has_include(<AppKit/AppKit.h>)
#import <AppKit/AppKit.h>
#define NC_APPKIT 1
typedef NSImage NCPlatformImage;
#endif

@implementation NCResourceResult
@end

#pragma mark - 状态

/// 以下状态在主线程写入；hook 可能在任意线程读取，统一加锁
static NSObject *NCResourcesLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

/// 已更新的 bundle 条目：相对资源目录的路径 → 新文件的绝对路径
static NSMutableDictionary<NSString *, NSString *> *gOverrides;
/// 已更新的图片：名字 → @{ images: 变体数组, template: 是否模板 }
static NSMutableDictionary<NSString *, NSDictionary *> *gImages;
/// 按名字缓存的新图，图片再次更新时清除
static NSMutableDictionary<NSString *, NCPlatformImage *> *gImageCache;
/// 当前镜像 bundle，以及历次生成的镜像 bundle 路径
static NSBundle *gMirrorBundle;
static NSMutableSet<NSString *> *gMirrorPaths;
/// 快速判断，避免没有资源更新时 hook 里也加锁
static volatile BOOL gHasOverrides = NO;
static volatile BOOL gHasImages = NO;
static NSUInteger gGeneration = 0;

/// 资源根目录在 bundle 内的相对路径：iOS 为空，macOS 为 Contents/Resources
static NSString *NCResourceSubpath(void) {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    if (resourcePath.length > bundlePath.length && [resourcePath hasPrefix:bundlePath]) {
        return [resourcePath substringFromIndex:bundlePath.length + 1];
    }
    return @"";
}

#pragma mark - 查询

/// 名字对应的已更新条目。name 为 storyboard / nib 名，ext 为 storyboardc / nib。
/// 同时匹配 xib 的设备变体（View~iphone.nib），任意 .lproj 下的条目都算
static NSString *NCOverrideItemNamed(NSString *name, NSString *ext) {
    if (!gHasOverrides || name.length == 0) {
        return nil;
    }
    @synchronized (NCResourcesLock()) {
        for (NSString *item in gOverrides) {
            NSString *file = item.lastPathComponent;
            if (![file.pathExtension isEqualToString:ext]) {
                continue;
            }
            NSString *stem = file.stringByDeletingPathExtension;
            if ([stem isEqualToString:name] || [stem hasPrefix:[name stringByAppendingString:@"~"]]) {
                return item;
            }
        }
    }
    return nil;
}

/// 文件名对应的已更新文件绝对路径（供 pathForResource: 系列使用）
static NSString *NCOverridePathForFile(NSString *fileName) {
    if (!gHasOverrides || fileName.length == 0) {
        return nil;
    }
    @synchronized (NCResourcesLock()) {
        for (NSString *item in gOverrides) {
            if (![item.lastPathComponent isEqualToString:fileName]) {
                continue;
            }
            NSString *directory = item.stringByDeletingLastPathComponent;
            // 只处理资源目录根部或 .lproj 下的条目，与 Xcode 拷贝资源的位置一致
            if (directory.length == 0 || [directory.pathExtension isEqualToString:@"lproj"]) {
                return gOverrides[item];
            }
        }
    }
    return nil;
}

static BOOL NCIsMainOrMirror(NSBundle *bundle) {
    return bundle == nil || bundle == NSBundle.mainBundle || [NCResources isMirrorBundle:bundle];
}

/// 加载 name.ext 时应使用的 bundle：资源已更新则返回镜像 bundle，否则原样返回
static NSBundle *NCRedirectBundle(NSBundle *bundle, NSString *name, NSString *ext) {
    if (!NCIsMainOrMirror(bundle) || !NCOverrideItemNamed(name, ext)) {
        return bundle;
    }
    @synchronized (NCResourcesLock()) {
        return gMirrorBundle ?: bundle;
    }
}

#pragma mark - 图片

/// 把 imageNamed: 的参数规范化为登记时的名字：去掉常见图片扩展名与倍率后缀
static NSString *NCNormalizedImageName(NSString *name) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"heif", @"webp"]];
    });
    NSString *result = name;
    if ([extensions containsObject:result.pathExtension.lowercaseString]) {
        result = result.stringByDeletingPathExtension;
    }
    NSRange at = [result rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound && [result hasSuffix:@"x"]) {
        result = [result substringToIndex:at.location];
    }
    return result;
}

#if NC_UIKIT
static UIImage *NCBuildImage(NSDictionary *entry) {
    NSArray<NSDictionary *> *variants = entry[@"images"];
    NSString *idiom = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone";
    // 先选设备类型：精确匹配 > universal > 其余
    NSArray<NSDictionary *> *candidates = [variants filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"idiom == %@", idiom]];
    if (candidates.count == 0) {
        candidates = [variants filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"idiom == 'universal'"]];
    }
    if (candidates.count == 0) {
        candidates = variants;
    }
    // 再选倍率：与屏幕一致 > 最大倍率
    CGFloat screenScale = UIScreen.mainScreen.scale;
    NSDictionary *best = nil;
    for (NSDictionary *variant in candidates) {
        CGFloat scale = [variant[@"scale"] doubleValue];
        if (fabs(scale - screenScale) < 0.01) {
            best = variant;
            break;
        }
        if (!best || scale > [best[@"scale"] doubleValue]) {
            best = variant;
        }
    }
    NSData *data = best ? [NSData dataWithContentsOfFile:best[@"absolutePath"]] : nil;
    if (!data) {
        return nil;
    }
    UIImage *image = [UIImage imageWithData:data scale:MAX([best[@"scale"] doubleValue], 1)];
    if ([entry[@"template"] boolValue]) {
        image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return image;
}
#else
static NSImage *NCBuildImage(NSDictionary *entry) {
    NSImage *image = nil;
    for (NSDictionary *variant in entry[@"images"]) {
        NSImageRep *rep = [NSImageRep imageRepWithContentsOfFile:variant[@"absolutePath"]];
        if (!rep) {
            continue;
        }
        CGFloat scale = MAX([variant[@"scale"] doubleValue], 1);
        NSSize size = NSMakeSize(rep.pixelsWide / scale, rep.pixelsHigh / scale);
        rep.size = size;
        if (!image) {
            image = [[NSImage alloc] initWithSize:size];
        }
        [image addRepresentation:rep];
    }
    image.template = [entry[@"template"] boolValue];
    return image;
}
#endif

/// 名字对应的新图；未更新过返回 nil
static NCPlatformImage *NCOverrideImageNamed(NSString *name) {
    if (!gHasImages || name.length == 0) {
        return nil;
    }
    NSString *key = NCNormalizedImageName(name);
    @synchronized (NCResourcesLock()) {
        NSDictionary *entry = gImages[key];
        if (!entry) {
            return nil;
        }
        NCPlatformImage *image = gImageCache[key];
        if (!image) {
            image = NCBuildImage(entry);
            if (image) {
                gImageCache[key] = image;
            }
        }
        return image;
    }
}

#pragma mark - Hook

static IMP NCHookClassMethod(Class cls, SEL sel, IMP replacement) {
    Method method = class_getClassMethod(cls, sel);
    if (!method) {
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

static IMP NCHookInstanceMethod(Class cls, SEL sel, IMP replacement) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

static IMP gOrigPathForResource;
static IMP gOrigURLForResource;

static NSString *NCPathForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    if (self == NSBundle.mainBundle && name.length > 0) {
        NSString *fileName = ext.length > 0 ? [name stringByAppendingPathExtension:ext] : name;
        NSString *path = NCOverridePathForFile(fileName);
        if (path) {
            return path;
        }
    }
    return ((NSString *(*)(id, SEL, NSString *, NSString *))gOrigPathForResource)(self, _cmd, name, ext);
}

static NSURL *NCURLForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    if (self == NSBundle.mainBundle && name.length > 0) {
        NSString *fileName = ext.length > 0 ? [name stringByAppendingPathExtension:ext] : name;
        NSString *path = NCOverridePathForFile(fileName);
        if (path) {
            return [NSURL fileURLWithPath:path];
        }
    }
    return ((NSURL *(*)(id, SEL, NSString *, NSString *))gOrigURLForResource)(self, _cmd, name, ext);
}

#if NC_UIKIT

/// nib 中引用的图片在解码时由 UIImageNibPlaceholder（UIImage 子类）的 initWithCoder: 生成，
/// 不经过 imageNamed:。交换其 initWithCoder:，资源名已更新时返回新图
@interface UIImage (NCResources)
- (instancetype)kg_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
@end

@implementation UIImage (NCResources)

- (instancetype)kg_initWithCoder:(NSCoder *)coder {
    // 交换后这里调用的是原始的 initWithCoder:。它通常直接返回从 Asset Catalog / bundle 取到的真实图片，
    // 资源名只能从 coder 中读取（nib 中的键为 UIResourceName）
    UIImage *image = [self kg_initWithCoder:coder];
    if (!gHasImages) {
        return image;
    }
    NSString *name = nil;
    if (coder.allowsKeyedCoding && [coder containsValueForKey:@"UIResourceName"]) {
        id value = [coder decodeObjectForKey:@"UIResourceName"];
        name = [value isKindOfClass:NSString.class] ? value : nil;
    }
    UIImage *override = NCOverrideImageNamed(name);
    if (!override) {
        return image;
    }
    if (image.renderingMode != UIImageRenderingModeAutomatic) {
        override = [override imageWithRenderingMode:image.renderingMode];
    }
    return override;
}

@end

static void NCHookNibImagePlaceholder(void) {
    Class cls = NSClassFromString(@"UIImageNibPlaceholder");
    Method original = cls ? class_getInstanceMethod(cls, @selector(initWithCoder:)) : NULL;
    Method replacement = class_getInstanceMethod(UIImage.class, @selector(kg_initWithCoder:));
    if (!original || !replacement) {
        return;
    }
    // 先把两个方法都加到子类上，交换时不影响 UIImage 本身
    class_addMethod(cls, @selector(initWithCoder:), method_getImplementation(original), method_getTypeEncoding(original));
    class_addMethod(cls, @selector(kg_initWithCoder:), method_getImplementation(replacement), method_getTypeEncoding(replacement));
    method_exchangeImplementations(class_getInstanceMethod(cls, @selector(initWithCoder:)),
                                   class_getInstanceMethod(cls, @selector(kg_initWithCoder:)));
}

static IMP gOrigStoryboardWithName;
static IMP gOrigNibWithName;
static IMP gOrigLoadNibNamed;
static IMP gOrigImageNamed;
static IMP gOrigImageNamedInBundleTraits;
static IMP gOrigImageNamedInBundleConfiguration;

static UIStoryboard *NCStoryboardWithName(id self, SEL _cmd, NSString *name, NSBundle *bundle) {
    return ((UIStoryboard *(*)(id, SEL, NSString *, NSBundle *))gOrigStoryboardWithName)(
        self, _cmd, name, NCRedirectBundle(bundle, name, @"storyboardc"));
}

static UINib *NCNibWithName(id self, SEL _cmd, NSString *name, NSBundle *bundle) {
    return ((UINib *(*)(id, SEL, NSString *, NSBundle *))gOrigNibWithName)(
        self, _cmd, name, NCRedirectBundle(bundle, name, @"nib"));
}

static NSArray *NCLoadNibNamed(NSBundle *self, SEL _cmd, NSString *name, id owner, NSDictionary *options) {
    NSBundle *target = NCRedirectBundle(self, name, @"nib");
    return ((NSArray *(*)(id, SEL, NSString *, id, NSDictionary *))gOrigLoadNibNamed)(target, _cmd, name, owner, options);
}

static UIImage *NCImageNamed(id self, SEL _cmd, NSString *name) {
    UIImage *image = NCOverrideImageNamed(name);
    if (image) {
        return image;
    }
    return ((UIImage *(*)(id, SEL, NSString *))gOrigImageNamed)(self, _cmd, name);
}

static UIImage *NCImageNamedInBundleTraits(id self, SEL _cmd, NSString *name, NSBundle *bundle, UITraitCollection *traits) {
    if (NCIsMainOrMirror(bundle)) {
        UIImage *image = NCOverrideImageNamed(name);
        if (image) {
            return image;
        }
    }
    return ((UIImage *(*)(id, SEL, NSString *, NSBundle *, UITraitCollection *))gOrigImageNamedInBundleTraits)(
        self, _cmd, name, bundle, traits);
}

static UIImage *NCImageNamedInBundleConfiguration(id self, SEL _cmd, NSString *name, NSBundle *bundle, id configuration) {
    if (NCIsMainOrMirror(bundle)) {
        UIImage *image = NCOverrideImageNamed(name);
        if (image) {
            return image;
        }
    }
    return ((UIImage *(*)(id, SEL, NSString *, NSBundle *, id))gOrigImageNamedInBundleConfiguration)(
        self, _cmd, name, bundle, configuration);
}

static void NCInstallPlatformHooks(void) {
    gOrigStoryboardWithName = NCHookClassMethod(UIStoryboard.class, @selector(storyboardWithName:bundle:), (IMP)NCStoryboardWithName);
    gOrigNibWithName = NCHookClassMethod(UINib.class, @selector(nibWithNibName:bundle:), (IMP)NCNibWithName);
    gOrigLoadNibNamed = NCHookInstanceMethod(NSBundle.class, @selector(loadNibNamed:owner:options:), (IMP)NCLoadNibNamed);
    gOrigImageNamed = NCHookClassMethod(UIImage.class, @selector(imageNamed:), (IMP)NCImageNamed);
    gOrigImageNamedInBundleTraits = NCHookClassMethod(UIImage.class, @selector(imageNamed:inBundle:compatibleWithTraitCollection:),
                                                      (IMP)NCImageNamedInBundleTraits);
    SEL configurationSel = NSSelectorFromString(@"imageNamed:inBundle:withConfiguration:");
    gOrigImageNamedInBundleConfiguration = NCHookClassMethod(UIImage.class, configurationSel, (IMP)NCImageNamedInBundleConfiguration);
    NCHookNibImagePlaceholder();
}

#else

static IMP gOrigStoryboardWithName;
static IMP gOrigNibInitWithName;
static IMP gOrigLoadNibNamed;
static IMP gOrigImageNamed;
static IMP gOrigImageForResource;

static NSStoryboard *NCStoryboardWithName(id self, SEL _cmd, NSString *name, NSBundle *bundle) {
    return ((NSStoryboard *(*)(id, SEL, NSString *, NSBundle *))gOrigStoryboardWithName)(
        self, _cmd, name, NCRedirectBundle(bundle, name, @"storyboardc"));
}

static id NCNibInitWithName(NSNib *self, SEL _cmd, NSString *name, NSBundle *bundle) {
    return ((id (*)(id, SEL, NSString *, NSBundle *))gOrigNibInitWithName)(
        self, _cmd, name, NCRedirectBundle(bundle, name, @"nib"));
}

static BOOL NCLoadNibNamed(NSBundle *self, SEL _cmd, NSString *name, id owner, NSArray **topLevelObjects) {
    NSBundle *target = NCRedirectBundle(self, name, @"nib");
    return ((BOOL (*)(id, SEL, NSString *, id, NSArray **))gOrigLoadNibNamed)(target, _cmd, name, owner, topLevelObjects);
}

static NSImage *NCImageNamed(id self, SEL _cmd, NSString *name) {
    NSImage *image = NCOverrideImageNamed(name);
    if (image) {
        return image;
    }
    return ((NSImage *(*)(id, SEL, NSString *))gOrigImageNamed)(self, _cmd, name);
}

static NSImage *NCImageForResource(NSBundle *self, SEL _cmd, NSString *name) {
    if (NCIsMainOrMirror(self)) {
        NSImage *image = NCOverrideImageNamed(name);
        if (image) {
            return image;
        }
    }
    return ((NSImage *(*)(id, SEL, NSString *))gOrigImageForResource)(self, _cmd, name);
}

static void NCInstallPlatformHooks(void) {
    gOrigStoryboardWithName = NCHookClassMethod(NSStoryboard.class, @selector(storyboardWithName:bundle:), (IMP)NCStoryboardWithName);
    gOrigNibInitWithName = NCHookInstanceMethod(NSNib.class, @selector(initWithNibNamed:bundle:), (IMP)NCNibInitWithName);
    gOrigLoadNibNamed = NCHookInstanceMethod(NSBundle.class, @selector(loadNibNamed:owner:topLevelObjects:), (IMP)NCLoadNibNamed);
    gOrigImageNamed = NCHookClassMethod(NSImage.class, @selector(imageNamed:), (IMP)NCImageNamed);
    gOrigImageForResource = NCHookInstanceMethod(NSBundle.class, @selector(imageForResource:), (IMP)NCImageForResource);
}

#endif

/// 首次更新资源时安装 hook，进程内只做一次
static void NCInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gOverrides = [NSMutableDictionary dictionary];
        gImages = [NSMutableDictionary dictionary];
        gImageCache = [NSMutableDictionary dictionary];
        gMirrorPaths = [NSMutableSet set];
        gOrigPathForResource = NCHookInstanceMethod(NSBundle.class, @selector(pathForResource:ofType:), (IMP)NCPathForResource);
        gOrigURLForResource = NCHookInstanceMethod(NSBundle.class, @selector(URLForResource:withExtension:), (IMP)NCURLForResource);
        NCInstallPlatformHooks();
    });
}

#pragma mark - 镜像 bundle

/// 在 mirrorDir 下镜像 realDir：overrides 中的条目（相对 realDir）指向新文件，其余条目软链接回原文件。
/// 只有被覆盖条目的上级目录才会真正创建，其余都是软链接，生成开销与 bundle 大小无关
static BOOL NCBuildMirror(NSString *realDir, NSString *mirrorDir, NSDictionary<NSString *, NSString *> *overrides) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:mirrorDir withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    // 按第一级路径分组：直接覆盖的叶子条目，与需要继续向下展开的目录
    NSMutableDictionary<NSString *, NSString *> *leaves = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *nested = [NSMutableDictionary dictionary];
    [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *relative, NSString *absolute, BOOL *stop) {
        NSArray<NSString *> *components = relative.pathComponents;
        if (components.count == 1) {
            leaves[components[0]] = absolute;
        } else if (components.count > 1) {
            NSString *rest = [NSString pathWithComponents:[components subarrayWithRange:NSMakeRange(1, components.count - 1)]];
            NSMutableDictionary *child = nested[components[0]];
            if (!child) {
                child = [NSMutableDictionary dictionary];
                nested[components[0]] = child;
            }
            child[rest] = absolute;
        }
    }];

    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSetWithArray:[fm contentsOfDirectoryAtPath:realDir error:nil] ?: @[]];
    [names addObjectsFromArray:leaves.allKeys];
    [names addObjectsFromArray:nested.allKeys];
    for (NSString *name in names) {
        NSString *target = [mirrorDir stringByAppendingPathComponent:name];
        NSString *real = [realDir stringByAppendingPathComponent:name];
        if (leaves[name]) {
            [fm createSymbolicLinkAtPath:target withDestinationPath:leaves[name] error:nil];
        } else if (nested[name]) {
            if (!NCBuildMirror(real, target, nested[name])) {
                return NO;
            }
        } else {
            [fm createSymbolicLinkAtPath:target withDestinationPath:real error:nil];
        }
    }
    return YES;
}

/// 按当前全部已更新条目重新生成镜像 bundle。每次换新路径，避免 NSBundle 按路径缓存旧实例
static BOOL NCRebuildMirrorBundle(void) {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *subpath = NCResourceSubpath();
    NSMutableDictionary<NSString *, NSString *> *relativeToBundle = [NSMutableDictionary dictionary];
    @synchronized (NCResourcesLock()) {
        [gOverrides enumerateKeysAndObjectsUsingBlock:^(NSString *item, NSString *absolute, BOOL *stop) {
            relativeToBundle[subpath.length > 0 ? [subpath stringByAppendingPathComponent:item] : item] = absolute;
        }];
    }
    gGeneration++;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"NoCompileResources/mirror_%lu", (unsigned long)gGeneration]];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    NSString *mirrorPath = [root stringByAppendingPathComponent:bundlePath.lastPathComponent];
    if (!NCBuildMirror(bundlePath, mirrorPath, relativeToBundle)) {
        return NO;
    }
    NSBundle *mirror = [NSBundle bundleWithPath:mirrorPath];
    if (!mirror) {
        return NO;
    }
    @synchronized (NCResourcesLock()) {
        gMirrorBundle = mirror;
        [gMirrorPaths addObject:mirrorPath];
    }
    return YES;
}

#pragma mark - NCResources

@implementation NCResources

+ (BOOL)isMirrorBundle:(NSBundle *)bundle {
    if (!bundle || !gHasOverrides) {
        return NO;
    }
    @synchronized (NCResourcesLock()) {
        return [gMirrorPaths containsObject:bundle.bundlePath];
    }
}

/// 把资源包落到本地目录：模拟器 / macOS 已由 Mac 端拷好，真机按文件列表从 data 中切出
+ (NSString *)materialize:(NSDictionary *)json data:(NSData *)data error:(NSString **)error {
    NSString *localRoot = json[@"localRoot"];
    if (localRoot.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:localRoot]) {
        return localRoot;
    }
    NSArray<NSDictionary *> *files = json[@"files"];
    if (![files isKindOfClass:NSArray.class] || files.count == 0) {
        *error = @"资源包缺少文件";
        return nil;
    }
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"NoCompileIncoming/%@", NSUUID.UUID.UUIDString]];
    NSUInteger offset = 0;
    for (NSDictionary *file in files) {
        NSString *relative = file[@"path"];
        NSUInteger length = [file[@"length"] unsignedIntegerValue];
        if (relative.length == 0 || [relative containsString:@".."] || offset + length > data.length) {
            *error = @"资源包数据不完整";
            return nil;
        }
        NSString *destination = [root stringByAppendingPathComponent:relative];
        [NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[data subdataWithRange:NSMakeRange(offset, length)] writeToFile:destination atomically:NO]) {
            *error = [NSString stringWithFormat:@"无法写入 %@", relative];
            return nil;
        }
        offset += length;
    }
    return root;
}

+ (NCResourceResult *)applyPackage:(NSDictionary *)json data:(NSData *)data {
    NCResourceResult *result = [NCResourceResult new];
    result.refreshedControllers = @[];
    NSString *error = nil;
    NSString *root = [self materialize:json data:data error:&error];
    if (!root) {
        result.message = error ?: @"资源包无效";
        return result;
    }
    if (NSThread.isMainThread) {
        [self applyPackage:json root:root result:result];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self applyPackage:json root:root result:result];
        });
    }
    return result;
}

+ (void)applyPackage:(NSDictionary *)json root:(NSString *)root result:(NCResourceResult *)result {
    NCInstallHooks();
    NSString *kind = json[@"kind"];
    NSString *name = json[@"name"];
    NSArray<NSString *> *items = json[@"items"];
    NSArray<NSDictionary *> *images = json[@"images"];

    // 1. 登记 bundle 条目并重建镜像 bundle
    if (items.count > 0) {
        @synchronized (NCResourcesLock()) {
            for (NSString *item in items) {
                gOverrides[item] = [root stringByAppendingPathComponent:item];
            }
        }
        gHasOverrides = YES;
        if (!NCRebuildMirrorBundle()) {
            result.message = @"无法生成镜像 bundle";
            return;
        }
    }

    // 2. 登记图片
    if ([kind isEqualToString:@"image"]) {
        NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
        for (NSDictionary *image in images) {
            NSMutableDictionary *variant = [image mutableCopy];
            variant[@"absolutePath"] = [root stringByAppendingPathComponent:image[@"path"]];
            [variants addObject:variant];
        }
        NSString *key = NCNormalizedImageName(name);
        @synchronized (NCResourcesLock()) {
            gImages[key] = @{ @"images": variants, @"template": json[@"template"] ?: @NO };
            [gImageCache removeObjectForKey:key];
        }
        gHasImages = YES;
    }

    // 3. 刷新可见界面
    NSArray<NSString *> *pending = nil;
    result.refreshedControllers = [NCSweeper refreshAfterResourceKind:kind name:name pendingControllers:&pending];
    result.pendingControllers = pending ?: @[];
    result.ok = YES;
}

@end

#endif
