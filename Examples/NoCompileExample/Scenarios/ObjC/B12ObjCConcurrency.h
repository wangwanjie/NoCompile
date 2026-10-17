//
//  B12ObjCConcurrency.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface B12ObjCConcurrency : NSObject

/// 后台定时反复调用 +tickText，注入时与主线程注入并发
+ (void)startTicking;
+ (NSString *)tickText;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
