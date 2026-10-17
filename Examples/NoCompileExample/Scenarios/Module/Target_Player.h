//
//  Target_Player.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 场景 M10：ObjC 的 Target，没有任何地方静态引用它，只被中介者按名字找到
@interface Target_Player : NSObject

- (NSString *)Action_info:(nullable NSDictionary *)params;

@end

NS_ASSUME_NONNULL_END
