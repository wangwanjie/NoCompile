//
//  ExSwizzleTarget.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 被 swizzle 的目标：-describe 被 +load 里的方法交换替换（场景 B07，仿 KGSafeKit）
@interface ExSwizzleTarget : NSObject

- (NSString *)describe;
/// 启动后 +load 执行的次数
+ (NSInteger)loadCount;

@end

NS_ASSUME_NONNULL_END
