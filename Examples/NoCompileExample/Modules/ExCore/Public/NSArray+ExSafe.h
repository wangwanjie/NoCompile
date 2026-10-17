//
//  NSArray+ExSafe.h
//  系统类的分类，方法加 kg_ 前缀
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSArray (ExSafe)

/// 越界返回 nil 而不是抛异常
- (nullable id)kg_safeObjectAtIndex:(NSUInteger)index;
- (NSString *)kg_safeDescription;

@end

NS_ASSUME_NONNULL_END
