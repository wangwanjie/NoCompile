//
//  B03NSStringCategory.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 场景 B03：给系统类 NSString 加分类（方法名带 kg_ 前缀）
@interface NSString (B03Tools)

- (NSString *)kg_b03Tag;

@end

@interface B03Probe : NSObject
+ (NSString *)probe;
@end

NS_ASSUME_NONNULL_END
