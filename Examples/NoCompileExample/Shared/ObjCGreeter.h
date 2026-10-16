//
//  ObjCGreeter.h
//  Objective-C 热重载验证
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCGreeter : NSObject

/// 修改 ObjCGreeter.m 中的返回值并保存，界面会自动刷新
+ (NSString *)message;

@end

NS_ASSUME_NONNULL_END
