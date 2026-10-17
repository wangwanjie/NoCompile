//
//  ExLogger.h
//  单例 + dispatch_once + 静态状态，常见于日志 / 配置中心
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ExLogSink)(NSString *line);

@interface ExLogger : NSObject

@property (nonatomic, copy, readonly) NSString *lastLine;
@property (nonatomic, assign, readonly) NSUInteger lineCount;

+ (instancetype)shared;
- (void)log:(NSString *)message;
- (void)addSink:(ExLogSink)sink;
/// 带版本令牌的描述（场景 M01）
- (NSString *)describeState;

@end

NS_ASSUME_NONNULL_END
