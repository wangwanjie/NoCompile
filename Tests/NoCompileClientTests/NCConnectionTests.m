//
//  NCConnectionTests.m
//  客户端帧收发：用 socketpair 模拟 Mac 端，按协议逐字节校验
//

#import <XCTest/XCTest.h>
#import "NCConnection.h"
#include <sys/socket.h>
#include <unistd.h>

@interface NCConnectionTests : XCTestCase <NCConnectionDelegate>
@property (nonatomic) NSMutableArray<NSDictionary *> *received;
@property (nonatomic, strong) XCTestExpectation *receiveExpectation;
@property (nonatomic, strong) XCTestExpectation *closeExpectation;
@end

@implementation NCConnectionTests {
    int _peer;
}

- (void)setUp {
    self.received = [NSMutableArray array];
    _peer = -1;
}

- (void)tearDown {
    if (_peer >= 0) {
        close(_peer);
    }
}

/// 建立一对相连的套接字，返回包装了其中一端的连接，另一端作为 Mac 端留在 _peer
- (NCConnection *)makeConnection {
    int fds[2];
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    _peer = fds[1];
    NCConnection *connection = [[NCConnection alloc] initWithSocket:fds[0]];
    connection.delegate = self;
    return connection;
}

/// 按协议拼一帧（与 Mac 端 NCFrameCodec 的布局一致）
- (NSData *)frameWithType:(uint32_t)type json:(NSDictionary *)json data:(NSData *)data {
    NSData *jsonData = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
    NCFrameHeader header = {0};
    header.magic = NC_PROTOCOL_MAGIC;
    header.type = type;
    header.jsonLength = (uint32_t)jsonData.length;
    header.dataLength = data.length;
    NSMutableData *frame = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    if (jsonData) {
        [frame appendData:jsonData];
    }
    if (data) {
        [frame appendData:data];
    }
    return frame;
}

- (void)writeToPeer:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    size_t sent = 0;
    while (sent < data.length) {
        ssize_t n = write(_peer, bytes + sent, data.length - sent);
        XCTAssertGreaterThan(n, 0);
        if (n <= 0) {
            return;
        }
        sent += (size_t)n;
    }
}

- (NSData *)readFromPeer:(size_t)length {
    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    size_t received = 0;
    while (received < length) {
        ssize_t n = read(_peer, (uint8_t *)buffer.mutableBytes + received, length - received);
        if (n <= 0) {
            return nil;
        }
        received += (size_t)n;
    }
    return buffer;
}

#pragma mark - NCConnectionDelegate

- (void)connectionDidOpen:(NCConnection *)connection {
}

- (void)connection:(NCConnection *)connection didReceiveType:(NCMessageType)type json:(NSDictionary *)json data:(NSData *)data {
    @synchronized (self) {
        [self.received addObject:@{ @"type": @(type), @"json": json ?: NSNull.null, @"data": data ?: NSNull.null }];
    }
    [self.receiveExpectation fulfill];
}

- (void)connection:(NCConnection *)connection didCloseWithError:(NSError *)error {
    [self.closeExpectation fulfill];
}

#pragma mark - 测试

- (void)testHeaderIsTwentyBytes {
    XCTAssertEqual(sizeof(NCFrameHeader), 20u);
}

- (void)testReceivesFramesWrittenInPieces {
    NCConnection *connection = [self makeConnection];
    self.receiveExpectation = [self expectationWithDescription:@"收到两帧"];
    self.receiveExpectation.expectedFulfillmentCount = 2;
    [connection open];

    uint8_t bytes[] = {1, 2, 3, 4, 5};
    NSMutableData *stream = [NSMutableData data];
    [stream appendData:[self frameWithType:NCMessageTypeInject json:@{ @"file": @"/a/中文.m" } data:[NSData dataWithBytes:bytes length:5]]];
    [stream appendData:[self frameWithType:NCMessageTypePing json:nil data:nil]];
    // 逐字节写入，验证读端能处理任意拆分的到达方式
    for (NSUInteger i = 0; i < stream.length; i++) {
        [self writeToPeer:[stream subdataWithRange:NSMakeRange(i, 1)]];
    }
    [self waitForExpectations:@[self.receiveExpectation] timeout:5];

    XCTAssertEqual(self.received.count, 2u);
    XCTAssertEqualObjects(self.received[0][@"type"], @(NCMessageTypeInject));
    XCTAssertEqualObjects(self.received[0][@"json"][@"file"], @"/a/中文.m");
    XCTAssertEqualObjects(self.received[0][@"data"], [NSData dataWithBytes:bytes length:5]);
    XCTAssertEqualObjects(self.received[1][@"type"], @(NCMessageTypePing));
    [connection close];
}

- (void)testSendWritesProtocolFrame {
    NCConnection *connection = [self makeConnection];
    [connection open];
    NSData *payload = [@"dylib" dataUsingEncoding:NSUTF8StringEncoding];
    [connection sendType:NCMessageTypeInjectResult json:@{ @"ok": @YES } data:payload];

    NSData *headerData = [self readFromPeer:sizeof(NCFrameHeader)];
    XCTAssertNotNil(headerData);
    NCFrameHeader header;
    memcpy(&header, headerData.bytes, sizeof(header));
    XCTAssertEqual(header.magic, NC_PROTOCOL_MAGIC);
    XCTAssertEqual(header.type, (uint32_t)NCMessageTypeInjectResult);
    XCTAssertEqual(header.dataLength, payload.length);
    NSData *json = [self readFromPeer:header.jsonLength];
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    XCTAssertEqualObjects(object[@"ok"], @YES);
    XCTAssertEqualObjects([self readFromPeer:(size_t)header.dataLength], payload);
    [connection close];
}

- (void)testInvalidJSONObjectIsDroppedWithoutCrashing {
    NCConnection *connection = [self makeConnection];
    [connection open];
    // NSDate 不是合法的 JSON 对象：不能抛异常让 App 崩溃，整帧丢弃
    [connection sendType:NCMessageTypeLog json:@{ @"date": [NSDate date] } data:nil];
    [connection sendType:NCMessageTypePong json:nil data:nil];
    NSData *headerData = [self readFromPeer:sizeof(NCFrameHeader)];
    NCFrameHeader header;
    memcpy(&header, headerData.bytes, sizeof(header));
    XCTAssertEqual(header.type, (uint32_t)NCMessageTypePong);
    [connection close];
}

- (void)testBadMagicClosesConnection {
    NCConnection *connection = [self makeConnection];
    self.closeExpectation = [self expectationWithDescription:@"关闭"];
    [connection open];
    NCFrameHeader header = {0};
    header.magic = 0xDEADBEEF;
    [self writeToPeer:[NSData dataWithBytes:&header length:sizeof(header)]];
    [self waitForExpectations:@[self.closeExpectation] timeout:5];
    XCTAssertFalse(connection.isOpen);
    XCTAssertEqual(self.received.count, 0u);
}

- (void)testOversizedFrameClosesConnection {
    NCConnection *connection = [self makeConnection];
    self.closeExpectation = [self expectationWithDescription:@"关闭"];
    [connection open];
    NCFrameHeader header = {0};
    header.magic = NC_PROTOCOL_MAGIC;
    header.type = NCMessageTypeInject;
    header.dataLength = NC_MAX_DATA_LENGTH + 1;
    [self writeToPeer:[NSData dataWithBytes:&header length:sizeof(header)]];
    [self waitForExpectations:@[self.closeExpectation] timeout:5];
    XCTAssertFalse(connection.isOpen);
}

- (void)testPeerCloseNotifiesDelegate {
    NCConnection *connection = [self makeConnection];
    self.closeExpectation = [self expectationWithDescription:@"关闭"];
    [connection open];
    close(_peer);
    _peer = -1;
    [self waitForExpectations:@[self.closeExpectation] timeout:5];
    XCTAssertFalse(connection.isOpen);
}

@end
