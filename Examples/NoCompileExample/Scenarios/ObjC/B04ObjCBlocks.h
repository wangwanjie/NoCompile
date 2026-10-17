//
//  B04ObjCBlocks.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *_Nonnull (^B04Formatter)(NSInteger value);

@interface B04ObjCBlocks : NSObject

@property (nonatomic, copy) B04Formatter formatter;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
