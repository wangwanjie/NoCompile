//
//  NCSweeper.h
//  注入后回调：遍历存活实例调用 -injected，对类调用 +injected，并发出通知
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NCSweeper : NSObject

/// 在主线程执行回调与实例遍历
+ (void)performSweepForClasses:(NSArray<Class> *)classes
                   sourceFiles:(nullable NSArray<NSString *> *)sourceFiles;

NS_ASSUME_NONNULL_END

@end
