//
//  ExObjCUser.h
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ObjC 类，内部调用同模块的 Swift @objc 类（通过 ExKit-Swift.h）
@interface ExObjCUser : NSObject

+ (NSString *)callSwift;

@end

NS_ASSUME_NONNULL_END
