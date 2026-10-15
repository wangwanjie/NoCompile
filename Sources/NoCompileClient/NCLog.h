//
//  NCLog.h
//  客户端日志：本地打印并转发到 Mac 端日志窗口
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NCLogLevel) {
    NCLogLevelInfo,
    NCLogLevelSuccess,
    NCLogLevelWarning,
    NCLogLevelError,
};

/// 日志转发回调，由 socket 客户端设置
typedef void (^NCLogForwarder)(NCLogLevel level, NSString *message);

void NCLogSetForwarder(_Nullable NCLogForwarder forwarder);
void NCLogMessage(NCLogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

#define NCLogInfo(...)    NCLogMessage(NCLogLevelInfo, __VA_ARGS__)
#define NCLogSuccess(...) NCLogMessage(NCLogLevelSuccess, __VA_ARGS__)
#define NCLogWarn(...)    NCLogMessage(NCLogLevelWarning, __VA_ARGS__)
#define NCLogError(...)   NCLogMessage(NCLogLevelError, __VA_ARGS__)

NS_ASSUME_NONNULL_END
