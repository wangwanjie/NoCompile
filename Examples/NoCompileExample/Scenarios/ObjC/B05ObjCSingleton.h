//
//  B05ObjCSingleton.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface B05ObjCSingleton : NSObject

@property (nonatomic, assign) NSInteger hits;
+ (instancetype)sharedInstance;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
