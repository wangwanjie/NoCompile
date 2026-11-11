//
//  NCMacPortScannerTests.m
//  Mac 端发现：扫描候选端口、与每个监听中的 Mac 端各保持一条连接、断开后重连、连接超时
//

#import <XCTest/XCTest.h>
#import "NCConnection.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

/// 模拟一个 Mac 端：在 127.0.0.1 的随机端口上监听，后台线程接受连接并保存对端描述符
@interface NCTestListener : NSObject
@property (nonatomic, readonly) uint16_t port;
/// 已接受的连接（对端描述符）
@property (atomic, readonly) NSArray<NSNumber *> *acceptedFDs;
- (instancetype)initListening;
/// 在指定端口上监听（0 表示由系统分配）
- (instancetype)initListeningOnPort:(uint16_t)port;
/// 关闭所有已接受的连接（模拟 Mac 端退出 / 引擎重启）
- (void)dropConnections;
- (void)stop;
@end

@implementation NCTestListener {
    int _fd;
    NSMutableArray<NSNumber *> *_accepted;
    NSLock *_lock;
}

- (instancetype)initListening {
    return [self initListeningOnPort:0];
}

- (instancetype)initListeningOnPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _lock = [NSLock new];
        _accepted = [NSMutableArray array];
        _fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        int on = 1;
        setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
        if (bind(_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(_fd, 8) != 0) {
            return nil;
        }
        socklen_t length = sizeof(addr);
        getsockname(_fd, (struct sockaddr *)&addr, &length);
        _port = ntohs(addr.sin_port);
        int listenFD = _fd;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (YES) {
                int client = accept(listenFD, NULL, NULL);
                if (client < 0) {
                    return;
                }
                [self->_lock lock];
                [self->_accepted addObject:@(client)];
                [self->_lock unlock];
            }
        });
    }
    return self;
}

- (NSArray<NSNumber *> *)acceptedFDs {
    [_lock lock];
    NSArray *copy = [_accepted copy];
    [_lock unlock];
    return copy;
}

- (void)dropConnections {
    [_lock lock];
    for (NSNumber *fd in _accepted) {
        close(fd.intValue);
    }
    [_accepted removeAllObjects];
    [_lock unlock];
}

- (void)stop {
    [self dropConnections];
    if (_fd >= 0) {
        // shutdown 唤醒阻塞在 accept 上的线程
        shutdown(_fd, SHUT_RDWR);
        close(_fd);
        _fd = -1;
    }
}

@end

/// 找一个当前没有进程监听的端口：先绑定拿到端口号，再立即关闭
static uint16_t NCUnusedPort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    socklen_t length = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &length);
    close(fd);
    return ntohs(addr.sin_port);
}

@interface NCMacPortScannerTests : XCTestCase <NCConnectionDelegate>
@property (nonatomic, strong) NSMutableArray<NCTestListener *> *listeners;
@property (nonatomic, strong) NSMutableArray<NCConnection *> *opened;
@property (nonatomic, strong) XCTestExpectation *closeExpectation;
@property (nonatomic, strong) XCTestExpectation *receiveExpectation;
@property (atomic, copy) NSDictionary *receivedJSON;
@end

@implementation NCMacPortScannerTests

- (void)setUp {
    self.listeners = [NSMutableArray array];
    self.opened = [NSMutableArray array];
}

- (void)tearDown {
    for (NCConnection *connection in self.opened) {
        [connection close];
    }
    for (NCTestListener *listener in self.listeners) {
        [listener stop];
    }
}

- (NCTestListener *)startListener {
    NCTestListener *listener = [[NCTestListener alloc] initListening];
    XCTAssertNotNil(listener);
    [self.listeners addObject:listener];
    return listener;
}

/// 等到 listener 接受了 count 条连接
- (void)waitForListener:(NCTestListener *)listener accepted:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (listener.acceptedFDs.count < count && deadline.timeIntervalSinceNow > 0) {
        usleep(10 * 1000);
    }
    XCTAssertEqual(listener.acceptedFDs.count, count);
}

- (void)openAll:(NSArray<NCConnection *> *)connections {
    for (NCConnection *connection in connections) {
        connection.delegate = self;
        [self.opened addObject:connection];
        [connection open];
    }
}

#pragma mark - 候选端口

- (void)testDefaultPortsCoverRangeAndSkipDevicePort {
    NSArray<NSNumber *> *ports = [NCMacPortScanner defaultPorts];
    XCTAssertEqual(ports.count, (NSUInteger)NC_MAC_PORT_COUNT - 1, "范围内只有设备端口被跳过");
    XCTAssertEqualObjects(ports.firstObject, @(NC_MAC_PORT));
    XCTAssertEqualObjects(ports.lastObject, @(NC_MAC_PORT + NC_MAC_PORT_COUNT - 1));
    XCTAssertFalse([ports containsObject:@(NC_DEVICE_PORT)]);
    XCTAssertEqual([NSSet setWithArray:ports].count, ports.count, "端口不重复");
}

#pragma mark - 扫描

- (void)testScanConnectsToEveryListeningPortAndSkipsClosedOnes {
    NCTestListener *first = [self startListener];
    NCTestListener *second = [self startListener];
    uint16_t closed = NCUnusedPort();
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1"
                                                                 ports:@[@(first.port), @(closed), @(second.port)]];
    NSArray<NCConnection *> *connections = [scanner scan];
    XCTAssertEqual(connections.count, 2, "两个监听中的 Mac 端各一条，没有监听的端口跳过");
    [self openAll:connections];
    [self waitForListener:first accepted:1];
    [self waitForListener:second accepted:1];
}

- (void)testRescanDoesNotDuplicateOpenConnections {
    NCTestListener *listener = [self startListener];
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1" ports:@[@(listener.port)]];
    [self openAll:[scanner scan]];
    XCTAssertEqual([scanner scan].count, 0, "已有打开的连接，不再重复连接");
    XCTAssertEqual([scanner scan].count, 0);
    [self waitForListener:listener accepted:1];
    usleep(100 * 1000);
    XCTAssertEqual(listener.acceptedFDs.count, 1);
}

- (void)testRescanKeepsConnectionThatIsNotOpenedYet {
    NCTestListener *listener = [self startListener];
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1" ports:@[@(listener.port)]];
    NSArray<NCConnection *> *pending = [scanner scan];
    XCTAssertEqual(pending.count, 1);
    XCTAssertFalse(pending.firstObject.hasStarted);
    XCTAssertEqual([scanner scan].count, 0, "调用方还没 open 的连接不算断开");
    [self openAll:pending];
}

- (void)testReconnectsAfterMacSideDropsConnection {
    NCTestListener *listener = [self startListener];
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1" ports:@[@(listener.port)]];
    self.closeExpectation = [self expectationWithDescription:@"连接断开"];
    [self openAll:[scanner scan]];
    [self waitForListener:listener accepted:1];
    // Mac 端退出 / 引擎重启
    [listener dropConnections];
    [self waitForExpectations:@[self.closeExpectation] timeout:3];
    self.closeExpectation = nil;
    NSArray<NCConnection *> *reconnected = [scanner scan];
    XCTAssertEqual(reconnected.count, 1, "断开后下一轮重新连接");
    [self openAll:reconnected];
    [self waitForListener:listener accepted:1];
}

- (void)testDiscoversMacSideStartedLater {
    uint16_t later = NCUnusedPort();
    NCTestListener *early = [self startListener];
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1"
                                                                 ports:@[@(early.port), @(later)]];
    NSArray<NCConnection *> *first = [scanner scan];
    XCTAssertEqual(first.count, 1, "第二个 Mac 端还没启动");
    [self openAll:first];
    // 第二个 Mac 端（另一个工程的 NoCompile）稍后在顺延后的端口上启动
    NCTestListener *second = [[NCTestListener alloc] initListeningOnPort:later];
    XCTAssertNotNil(second);
    [self.listeners addObject:second];
    NSArray<NCConnection *> *found = [scanner scan];
    XCTAssertEqual(found.count, 1, "下一轮扫描发现新的 Mac 端，已有的连接不重复建立");
    [self openAll:found];
    [self waitForListener:second accepted:1];
    [self waitForListener:early accepted:1];
}

- (void)testScanWithNothingListeningReturnsQuickly {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        [ports addObject:@(NCUnusedPort())];
    }
    NCMacPortScanner *scanner = [[NCMacPortScanner alloc] initWithHost:@"127.0.0.1" ports:ports];
    NSDate *began = [NSDate date];
    XCTAssertEqual([scanner scan].count, 0);
    XCTAssertLessThan(-began.timeIntervalSinceNow, 1.0, "本机没有监听时连接立即被拒绝，扫描不应阻塞");
}

#pragma mark - connectToHost

- (void)testConnectToInvalidHostReturnsNil {
    XCTAssertNil([NCConnection connectToHost:@"not-an-ip" port:NC_MAC_PORT]);
}

- (void)testConnectionIsBlockingAfterConnectAndReceivesFrames {
    NCTestListener *listener = [self startListener];
    NCConnection *connection = [NCConnection connectToHost:@"127.0.0.1" port:listener.port];
    XCTAssertNotNil(connection);
    self.receiveExpectation = [self expectationWithDescription:@"收到帧"];
    [self openAll:@[connection]];
    [self waitForListener:listener accepted:1];
    // 连接建立时临时设成非阻塞，之后必须恢复为阻塞：否则读循环会在没有数据时立即读到 EAGAIN 并断开
    usleep(200 * 1000);
    XCTAssertTrue(connection.isOpen, "空闲时连接应保持打开");
    NSDictionary *json = @{ @"message": @"你好" };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    NCFrameHeader header = {0};
    header.magic = NC_PROTOCOL_MAGIC;
    header.type = NCMessageTypeStatus;
    header.jsonLength = (uint32_t)jsonData.length;
    NSMutableData *frame = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    [frame appendData:jsonData];
    int peer = listener.acceptedFDs.firstObject.intValue;
    XCTAssertEqual(write(peer, frame.bytes, frame.length), (ssize_t)frame.length);
    [self waitForExpectations:@[self.receiveExpectation] timeout:3];
    XCTAssertEqualObjects(self.receivedJSON, json);
}

#pragma mark - NCConnectionDelegate

- (void)connection:(NCConnection *)connection didReceiveType:(NCMessageType)type json:(NSDictionary *)json data:(NSData *)data {
    self.receivedJSON = json;
    [self.receiveExpectation fulfill];
}

- (void)connectionDidOpen:(NCConnection *)connection {
}

- (void)connection:(NCConnection *)connection didCloseWithError:(NSError *)error {
    [self.closeExpectation fulfill];
}

@end
