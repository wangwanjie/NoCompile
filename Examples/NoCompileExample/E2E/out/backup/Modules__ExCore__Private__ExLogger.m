//
//  ExLogger.m
//  场景 M01：framework 内的 ObjC 单例；热重载后单例实例和计数必须保留
//

#import <ExCore/ExLogger.h>

@interface ExLogger ()
@property (nonatomic, copy, readwrite) NSString *lastLine;
@property (nonatomic, assign, readwrite) NSUInteger lineCount;
@property (nonatomic, strong) NSMutableArray<ExLogSink> *sinks;
@end

@implementation ExLogger

+ (instancetype)shared {
    static ExLogger *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ExLogger alloc] init];
        instance.sinks = [NSMutableArray array];
        instance.lastLine = @"";
    });
    return instance;
}

- (void)log:(NSString *)message {
    @synchronized (self) {
        self.lastLine = message;
        self.lineCount += 1;
        for (ExLogSink sink in self.sinks) {
            sink(message);
        }
    }
}

- (void)addSink:(ExLogSink)sink {
    @synchronized (self) {
        [self.sinks addObject:[sink copy]];
    }
}

- (NSString *)describeState {
    return [NSString stringWithFormat:@"ExLogger:@@v1@@ lines=%lu", (unsigned long)self.lineCount];
}

@end
