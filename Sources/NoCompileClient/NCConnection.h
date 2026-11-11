//
//  NCConnection.h
//  与 Mac 端的 socket 连接（收发协议帧）
//

#import <Foundation/Foundation.h>
#import "NCProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@class NCConnection;

@protocol NCConnectionDelegate <NSObject>
/// 收到一帧完整消息
- (void)connection:(NCConnection *)connection
    didReceiveType:(NCMessageType)type
              json:(nullable NSDictionary *)json
              data:(nullable NSData *)data;
- (void)connectionDidOpen:(NCConnection *)connection;
- (void)connection:(NCConnection *)connection didCloseWithError:(nullable NSError *)error;
@end

@interface NCConnection : NSObject

@property (nonatomic, weak) id<NCConnectionDelegate> delegate;
@property (nonatomic, readonly, getter=isOpen) BOOL open;
/// 是否调用过 open（调用过之后关闭的连接不会再打开）
@property (nonatomic, readonly) BOOL hasStarted;

/// 以已连接的文件描述符构造（真机 USB 监听 accept 后使用）
- (instancetype)initWithSocket:(int)fd;

/// 主动连接 TCP 主机（模拟器 / macOS 使用）
+ (nullable instancetype)connectToHost:(NSString *)host port:(uint16_t)port;

- (void)open;
- (void)close;

/// 发送一帧
- (void)sendType:(NCMessageType)type json:(nullable NSDictionary *)json data:(nullable NSData *)data;

@end

/// 发现 Mac 端：Mac 端的监听端口不固定（起始端口被占用时顺延），扫描整个候选范围，
/// 与每个监听中的 Mac 端各保持一条连接。只在扫描线程上使用，不是线程安全的
@interface NCMacPortScanner : NSObject

/// 默认候选端口：NC_MAC_PORT 起 NC_MAC_PORT_COUNT 个，跳过 NC_DEVICE_PORT
+ (NSArray<NSNumber *> *)defaultPorts;

- (instancetype)initWithHost:(NSString *)host ports:(NSArray<NSNumber *> *)ports;

/// 扫描一轮：已有打开连接的端口跳过，其余端口尝试连接。返回本轮新建立的连接（尚未 open，由调用方设置代理后打开）
- (NSArray<NCConnection *> *)scan;

@end

NS_ASSUME_NONNULL_END
