//
//  B09ObjCProperties.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface B09ObjCProperties : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, assign, readonly) NSInteger doubled;

+ (NSString *)probe;

@end

NS_ASSUME_NONNULL_END
