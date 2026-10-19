//
//  NoCompile.m
//  客户端入口与连接管理
//

#import "NoCompile.h"

NSNotificationName const NoCompileDidInjectNotification = @"NoCompileDidInjectNotification";
NSNotificationName const NoCompileInjectionBundleNotification = @"INJECTION_BUNDLE_NOTIFICATION";
NSString * const NoCompileInjectedFilesKey = @"files";

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCConnection.h"
#import "NCInjector.h"
#import "NCResources.h"
#import "NCSwizzleGuard.h"
#import "NCLog.h"
#import "NCHUD.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/utsname.h>

@interface NoCompile () <NCConnectionDelegate>
+ (instancetype)shared;
- (void)startWithHost:(nullable NSString *)host;
@property (nonatomic, strong) NCConnection *connection;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) BOOL started;
@property (nonatomic) int listenFD;
@end

@implementation NoCompile

static BOOL gAutoReloadViewControllers = NO;
static BOOL gPreserveStaticState = YES;
static BOOL gShowsHUD = YES;
static BOOL gSuppressSwizzlingDuringLoad = YES;
static NSUInteger gInjectionCount = 0;

+ (BOOL)autoReloadViewControllers { return gAutoReloadViewControllers; }
+ (void)setAutoReloadViewControllers:(BOOL)value { gAutoReloadViewControllers = value; }
+ (BOOL)preserveStaticState { return gPreserveStaticState; }
+ (void)setPreserveStaticState:(BOOL)value { gPreserveStaticState = value; }
+ (BOOL)showsHUD { return gShowsHUD; }
+ (void)setShowsHUD:(BOOL)value { gShowsHUD = value; }
+ (BOOL)suppressSwizzlingDuringLoad { return gSuppressSwizzlingDuringLoad; }
+ (void)setSuppressSwizzlingDuringLoad:(BOOL)value { gSuppressSwizzlingDuringLoad = value; }
+ (NSUInteger)injectionCount { return gInjectionCount; }

+ (instancetype)shared {
    static NoCompile *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [NoCompile new];
        instance.listenFD = -1;
    });
    return instance;
}

+ (BOOL)isConnected {
    return [self shared].connection.isOpen;
}

+ (void)start {
    [[self shared] startWithHost:nil];
}

+ (void)startWithHost:(NSString *)host {
    [[self shared] startWithHost:host];
}

- (void)startWithHost:(NSString *)host {
    if (self.started) {
        return;
    }
    self.started = YES;
    self.host = host;

    NCSwizzleGuardInstall();
    NCLogSetForwarder(^(NCLogLevel level, NSString *message) {
        [self forwardLog:level message:message];
    });

#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
    // 模拟器 / macOS：主动连接本机 Mac 端
    [self connectLoop];
#else
    // 真机：监听回环端口，等待 Mac 经 usbmuxd 连入；若设置了 host 则同时尝试 Wi-Fi
    [self startDeviceListener];
    if (host.length > 0) {
        [self connectLoop];
    }
#endif
}

#pragma mark - 连接（模拟器 / macOS / 真机 Wi-Fi）

- (void)connectLoop {
    NSString *host = self.host.length > 0 ? self.host : @"127.0.0.1";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (self.started) {
            if (!self.connection.isOpen) {
                NCConnection *connection = [NCConnection connectToHost:host port:NC_MAC_PORT];
                if (connection) {
                    connection.delegate = self;
                    self.connection = connection;
                    [connection open];
                }
            }
            sleep(2); // 每 2 秒重连一次
        }
    });
}

#pragma mark - 设备监听（真机 USB）

- (void)startDeviceListener {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            return;
        }
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(NC_DEVICE_PORT);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 1) != 0) {
            close(fd);
            return;
        }
        self.listenFD = fd;
        while (self.started) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) {
                break;
            }
            NCConnection *connection = [[NCConnection alloc] initWithSocket:client];
            connection.delegate = self;
            self.connection = connection;
            [connection open];
        }
        close(fd);
    });
}

#pragma mark - NCConnectionDelegate

- (void)connectionDidOpen:(NCConnection *)connection {
    [self sendHello];
    NCLogInfo(@"已连接到 NoCompile Mac 端");
}

- (void)connection:(NCConnection *)connection didCloseWithError:(NSError *)error {
    if (self.connection == connection) {
        self.connection = nil;
    }
}

- (void)connection:(NCConnection *)connection
    didReceiveType:(NCMessageType)type
              json:(NSDictionary *)json
              data:(NSData *)data {
    switch (type) {
        case NCMessageTypeInject:
            [self handleInject:json data:data];
            break;
        case NCMessageTypeResource:
            [self handleResource:json data:data];
            break;
        case NCMessageTypeStatus:
            [self handleStatus:json];
            break;
        case NCMessageTypeHelloAck:
        case NCMessageTypeConfig:
            [self applyConfig:json[@"config"]];
            break;
        case NCMessageTypePing:
            [connection sendType:NCMessageTypePong json:nil data:nil];
            break;
        default:
            break;
    }
}

#pragma mark - 消息处理

/// 客户端自身所在镜像的路径与 LC_UUID。bundle 方式接入时，Mac 端据此判断 App 包内的 bundle 是否与当前 Mac 端随附的一致
- (void)clientImagePath:(NSString **)outPath uuid:(NSString **)outUUID {
    Dl_info info;
    if (dladdr((__bridge const void *)NoCompile.class, &info) == 0 || info.dli_fbase == NULL) {
        return;
    }
    if (info.dli_fname) {
        *outPath = @(info.dli_fname);
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (header->magic != MH_MAGIC_64) {
        return;
    }
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuidCommand = (const struct uuid_command *)command;
            *outUUID = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid].UUIDString;
            return;
        }
        cursor += command->cmdsize;
    }
}

- (void)sendHello {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *imagePath = @"";
    NSString *imageUUID = @"";
    [self clientImagePath:&imagePath uuid:&imageUUID];
    NSDictionary *hello = @{
        @"protocol": @(NC_PROTOCOL_VERSION),
        @"clientVersion": NC_CLIENT_VERSION,
        @"clientRevision": @(NC_CLIENT_REVISION),
        @"clientImage": imagePath ?: @"",
        @"clientUUID": imageUUID ?: @"",
        @"bundleID": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"bundlePath": NSBundle.mainBundle.bundlePath ?: @"",
        @"executable": NSBundle.mainBundle.executablePath ?: @"",
        @"machine": @(systemInfo.machine),
#if TARGET_OS_SIMULATOR
        @"platform": @"simulator",
#elif TARGET_OS_OSX
        @"platform": @"macosx",
#else
        @"platform": @"device",
#endif
        @"home": NSHomeDirectory(),
        @"tmp": NSTemporaryDirectory(),
    };
    [self.connection sendType:NCMessageTypeHello json:hello data:nil];
}

/// 应用 Mac 端下发的偏好设置
- (void)applyConfig:(NSDictionary *)config {
    if (![config isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSNumber *autoReload = config[@"autoReloadViewControllers"];
    if (autoReload) {
        gAutoReloadViewControllers = autoReload.boolValue;
    }
    NSNumber *preserveStatics = config[@"preserveStaticState"];
    if (preserveStatics) {
        gPreserveStaticState = preserveStatics.boolValue;
    }
    NSNumber *showsHUD = config[@"showsHUD"];
    if (showsHUD) {
        gShowsHUD = showsHUD.boolValue;
    }
    NSNumber *suppress = config[@"suppressSwizzlingDuringLoad"];
    if (suppress) {
        gSuppressSwizzlingDuringLoad = suppress.boolValue;
    }
}

- (void)handleStatus:(NSDictionary *)json {
    NSString *message = json[@"message"];
    NSInteger state = [json[@"state"] integerValue];
    if (gShowsHUD && message) {
        [NCHUD showStatus:message state:state];
    }
}

- (void)handleInject:(NSDictionary *)json data:(NSData *)data {
    NSString *dylibName = json[@"dylibName"] ?: @"nocompile_injection.dylib";
    NSArray<NSString *> *sourceFiles = json[@"sourceFiles"];
    NSString *localPath = json[@"localPath"];
    BOOL isNewFile = [json[@"newFile"] boolValue];

    NSString *dylibPath;
    if (localPath.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:localPath]) {
        // 模拟器 / macOS：Mac 端已把 dylib 写到共享文件系统，直接使用路径
        dylibPath = localPath;
    } else if (data.length > 0) {
        // 真机：dylib 随帧传输，落盘到可执行目录
        dylibPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dylibName];
        [data writeToFile:dylibPath atomically:YES];
    } else {
        [self sendInjectResult:NO message:@"注入请求缺少 dylib" source:sourceFiles];
        return;
    }

    if (gShowsHUD) {
        [NCHUD showStatus:@"注入中…" state:1];
    }

    NCInjectResult *result = [NCInjector injectDylibAtPath:dylibPath sourceFiles:sourceFiles isNewFile:isNewFile];
    BOOL ok = result.status == NCInjectStatusSuccess;
    NSString *fileName = sourceFiles.firstObject.lastPathComponent ?: dylibName;
    NSString *hud;
    if (ok) {
        gInjectionCount++;
        NSString *refreshed = result.refreshedControllers.count > 0
            ? [NSString stringWithFormat:@"，已刷新 %@", [result.refreshedControllers componentsJoinedByString:@"、"]]
            : @"";
        NSString *categories = result.categoriesAttached > 0
            ? [NSString stringWithFormat:@"，分类 %lu", (unsigned long)result.categoriesAttached]
            : @"";
        NCLogSuccess(@"%@%@ 注入成功：ObjC 方法 %lu，Swift 槽位 %lu，函数重绑 %lu%@%@",
                     fileName,
                     isNewFile ? @"（新增文件）" : @"",
                     (unsigned long)result.objcMethodsReplaced,
                     (unsigned long)result.swiftSlotsPatched,
                     (unsigned long)result.symbolsRebound,
                     categories,
                     refreshed);
        if (result.layoutChangedClasses.count > 0) {
            NCLogWarn(@"%@ 增删了方法/属性：ObjC/@objc 方法已即时生效；纯 Swift 的增删需重新运行 App 才会在新实例上体现",
                      [result.layoutChangedClasses componentsJoinedByString:@"、"]);
        }
        hud = [self successHUDForFile:fileName pending:result.pendingControllers];
    } else {
        NCLogError(@"%@ 注入失败：%@", fileName, result.message);
        hud = [NSString stringWithFormat:@"%@ 注入失败", fileName];
    }
    if (gShowsHUD) {
        [NCHUD showStatus:hud state:ok ? 0 : 2];
    }
    [self sendInjectResult:ok
                   message:result.message
                    source:sourceFiles
                 refreshed:result.refreshedControllers
                   pending:result.pendingControllers];
}

/// 成功提示：有未自动重建的已加载页面时，打印日志并在浮层提示用户退出页面后重新进入
- (NSString *)successHUDForFile:(NSString *)fileName pending:(NSArray<NSString *> *)pending {
    if (pending.count == 0) {
        return [NSString stringWithFormat:@"%@ 已生效", fileName];
    }
    NCLogWarn(@"%@ 已加载，未自动重建：退出该页面后重新进入即可看到改动",
              [pending componentsJoinedByString:@"、"]);
    return [NSString stringWithFormat:@"%@ 已生效，退出页面重进即可看到", fileName];
}

/// 资源更新：storyboard / xib 编译产物与图片
- (void)handleResource:(NSDictionary *)json data:(NSData *)data {
    NSString *source = json[@"source"] ?: @"";
    NSString *fileName = source.lastPathComponent.length > 0 ? source.lastPathComponent : (json[@"name"] ?: @"资源");
    if (gShowsHUD) {
        [NCHUD showStatus:@"更新资源…" state:1];
    }
    NCResourceResult *result = [NCResources applyPackage:json data:data];
    NSString *hud;
    if (result.ok) {
        gInjectionCount++;
        NSString *refreshed = result.refreshedControllers.count > 0
            ? [NSString stringWithFormat:@"，已刷新 %@", [result.refreshedControllers componentsJoinedByString:@"、"]]
            : @"";
        NCLogSuccess(@"%@ 资源已更新%@", fileName, refreshed);
        hud = [self successHUDForFile:fileName pending:result.pendingControllers];
    } else {
        NCLogError(@"%@ 资源更新失败：%@", fileName, result.message);
        hud = [NSString stringWithFormat:@"%@ 更新失败", fileName];
    }
    if (gShowsHUD) {
        [NCHUD showStatus:hud state:result.ok ? 0 : 2];
    }
    [self.connection sendType:NCMessageTypeResourceResult
                         json:@{ @"ok": @(result.ok),
                                 @"message": result.message ?: @"",
                                 @"sourceFiles": @[source],
                                 @"refreshed": result.refreshedControllers ?: @[],
                                 @"pending": result.pendingControllers ?: @[] }
                         data:nil];
}

- (void)sendInjectResult:(BOOL)ok message:(NSString *)message source:(NSArray<NSString *> *)source {
    [self sendInjectResult:ok message:message source:source refreshed:nil pending:nil];
}

- (void)sendInjectResult:(BOOL)ok
                 message:(NSString *)message
                  source:(NSArray<NSString *> *)source
               refreshed:(NSArray<NSString *> *)refreshed
                 pending:(NSArray<NSString *> *)pending {
    [self.connection sendType:NCMessageTypeInjectResult
                         json:@{ @"ok": @(ok),
                                 @"message": message ?: @"",
                                 @"sourceFiles": source ?: @[],
                                 @"refreshed": refreshed ?: @[],
                                 @"pending": pending ?: @[] }
                         data:nil];
}

- (void)forwardLog:(NCLogLevel)level message:(NSString *)message {
    [self.connection sendType:NCMessageTypeLog
                         json:@{ @"level": @(level), @"message": message }
                         data:nil];
}

@end

#endif
