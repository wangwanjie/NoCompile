//
//  ExMediator.h
//  Target-Action 组件化中介者（仿 CTMediator 模式）：
//  运行时用 NSClassFromString + performSelector 调用各业务模块暴露的 Target_xxx 类
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExMediator : NSObject

+ (instancetype)shared;
/// 调用 Target_<target> 的 Action_<action>: 方法，找不到返回 nil
- (nullable id)performTarget:(NSString *)target action:(NSString *)action params:(nullable NSDictionary *)params;

@end

NS_ASSUME_NONNULL_END
