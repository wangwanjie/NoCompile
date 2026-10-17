//
//  B07SwizzleHost.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 场景 B07：App 自己的类，在 +load 里做 swizzle。对应 KuGou 里大量的 +load swizzle
@interface B07SwizzleHost : NSObject

- (NSString *)work;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
