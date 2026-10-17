//
//  C03Catcher.mm
//

#import <Foundation/Foundation.h>
#include "C03Error.hpp"

@interface C03Catcher : NSObject
+ (NSString *)probe;
@end

@implementation C03Catcher

+ (NSString *)probe {
    try {
        c03Throw();
    } catch (const C03Error &error) {
        return [NSString stringWithFormat:@"typed:%s", error.what()];
    } catch (const std::exception &error) {
        // 说明 typeinfo 不匹配，只能当作基类捕获
        return [NSString stringWithFormat:@"base-only:%s", error.what()];
    }
    return @"nothing";
}

@end
