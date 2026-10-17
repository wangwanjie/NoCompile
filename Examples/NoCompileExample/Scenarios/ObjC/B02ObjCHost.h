//
//  B02ObjCHost.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface B02ObjCHost : NSObject

- (NSString *)hostName;
+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
