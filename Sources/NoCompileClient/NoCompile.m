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
#import "NCSwizzleGuard.h"
#import "NCLog.h"
#import "NCHUD.h"
#include <mach-o/dyld.h>
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

static BOOL gAutoReloadViewControllers = YES;
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
        case NCMessageTypeStatus:
            [self handleStatus:json];
            break;
        case NCMessageTypePing:
            [connection sendType:NCMessageTypePong json:nil data:nil];
            break;
        default:
            break;
    }
}

#pragma mark - 消息处理

- (void)sendHello {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            [images addObject:@(name)];
        }
    }
    NSDictionary *hello = @{
        @"protocol": @(NC_PROTOCOL_VERSION),
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

    NCInjectResult *result = [NCInjector injectDylibAtPath:dylibPath sourceFiles:sourceFiles];
    BOOL ok = result.status == NCInjectStatusSuccess;
    if (ok) {
        gInjectionCount++;
        NCLogSuccess(@"注入成功：替换 ObjC 方法 %lu，Swift 槽位 %lu，重绑符号 %lu",
                     (unsigned long)result.objcMethodsReplaced,
                     (unsigned long)result.swiftSlotsPatched,
                     (unsigned long)result.symbolsRebound);
    } else {
        NCLogError(@"注入失败：%@", result.message);
    }
    if (gShowsHUD) {
        [NCHUD showStatus:ok ? @"注入成功" : @"注入失败" state:ok ? 0 : 2];
    }
    [self sendInjectResult:ok message:result.message source:sourceFiles];
}

- (void)sendInjectResult:(BOOL)ok message:(NSString *)message source:(NSArray<NSString *> *)source {
    [self.connection sendType:NCMessageTypeInjectResult
                         json:@{ @"ok": @(ok), @"message": message ?: @"", @"sourceFiles": source ?: @[] }
                         data:nil];
}

- (void)forwardLog:(NCLogLevel)level message:(NSString *)message {
    [self.connection sendType:NCMessageTypeLog
                         json:@{ @"level": @(level), @"message": message }
                         data:nil];
}

@end

#endif
