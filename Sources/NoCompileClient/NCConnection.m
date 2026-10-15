//
//  NCConnection.m
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCConnection.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

@implementation NCConnection {
    int _fd;
    dispatch_queue_t _ioQueue;
    BOOL _open;
}

- (instancetype)initWithSocket:(int)fd {
    self = [super init];
    if (self) {
        _fd = fd;
        _ioQueue = dispatch_queue_create("com.nocompile.connection", DISPATCH_QUEUE_SERIAL);
        [self configureSocket];
    }
    return self;
}

+ (instancetype)connectToHost:(NSString *)host port:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return nil;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
        close(fd);
        return nil;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return nil;
    }
    return [[self alloc] initWithSocket:fd];
}

- (void)configureSocket {
    int on = 1;
    setsockopt(_fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

- (BOOL)isOpen {
    return _open;
}

- (void)open {
    if (_open) {
        return;
    }
    _open = YES;
    [self.delegate connectionDidOpen:self];
    dispatch_async(_ioQueue, ^{
        [self readLoop];
    });
}

- (void)close {
    if (!_open) {
        return;
    }
    _open = NO;
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

#pragma mark - 读

/// 阻塞读满 length 字节；失败返回 NO
- (BOOL)readFully:(void *)buffer length:(size_t)length {
    size_t received = 0;
    uint8_t *cursor = buffer;
    while (received < length) {
        ssize_t n = read(_fd, cursor + received, length - received);
        if (n <= 0) {
            return NO;
        }
        received += (size_t)n;
    }
    return YES;
}

- (void)readLoop {
    while (_open) {
        NCFrameHeader header = {0};
        if (![self readFully:&header length:sizeof(header)]) {
            break;
        }
        if (header.magic != NC_PROTOCOL_MAGIC) {
            [self failWithReason:@"协议魔数不匹配"];
            return;
        }
        if (header.jsonLength > NC_MAX_JSON_LENGTH || header.dataLength > NC_MAX_DATA_LENGTH) {
            [self failWithReason:@"帧长度超出上限"];
            return;
        }
        NSDictionary *json = nil;
        NSData *data = nil;
        if (header.jsonLength > 0) {
            NSMutableData *jsonData = [NSMutableData dataWithLength:header.jsonLength];
            if (![self readFully:jsonData.mutableBytes length:header.jsonLength]) {
                break;
            }
            json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
        }
        if (header.dataLength > 0) {
            NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)header.dataLength];
            if (![self readFully:payload.mutableBytes length:(size_t)header.dataLength]) {
                break;
            }
            data = payload;
        }
        [self.delegate connection:self didReceiveType:(NCMessageType)header.type json:json data:data];
    }
    if (_open) {
        [self failWithReason:@"连接已断开"];
    }
}

- (void)failWithReason:(NSString *)reason {
    [self close];
    NSError *error = [NSError errorWithDomain:@"NoCompile" code:-1
                                     userInfo:@{ NSLocalizedDescriptionKey: reason }];
    [self.delegate connection:self didCloseWithError:error];
}

#pragma mark - 写

- (void)sendType:(NCMessageType)type json:(NSDictionary *)json data:(NSData *)data {
    NSData *jsonData = nil;
    if (json) {
        jsonData = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    }
    NCFrameHeader header = {0};
    header.magic = NC_PROTOCOL_MAGIC;
    header.type = type;
    header.jsonLength = (uint32_t)jsonData.length;
    header.dataLength = (uint64_t)data.length;

    NSMutableData *frame = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    if (jsonData) {
        [frame appendData:jsonData];
    }
    if (data) {
        [frame appendData:data];
    }
    dispatch_async(_ioQueue, ^{
        [self writeFully:frame];
    });
}

- (void)writeFully:(NSData *)frame {
    const uint8_t *bytes = frame.bytes;
    size_t total = frame.length;
    size_t sent = 0;
    while (sent < total && _open) {
        ssize_t n = write(_fd, bytes + sent, total - sent);
        if (n <= 0) {
            [self failWithReason:@"写入失败"];
            return;
        }
        sent += (size_t)n;
    }
}

@end

#endif
