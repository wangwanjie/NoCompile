//
//  H01UserCpp.mm
//  引用 H01Macros.h 的 ObjC++ 文件
//

#import "H01Macros.h"
#import <Foundation/Foundation.h>

@interface H01UserCpp : NSObject
+ (NSString *)probe;
@end

@implementation H01UserCpp

+ (NSString *)probe {
    return [NSString stringWithFormat:@"mm:%s", H01_TOKEN];
}

@end
