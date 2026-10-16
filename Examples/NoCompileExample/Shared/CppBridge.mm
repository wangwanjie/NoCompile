//
//  CppBridge.mm
//  ObjC++ 桥接：调用 C++ 类并转成 NSString
//

#import "CppBridge.h"
#include "CppCounter.hpp"

@implementation CppBridge

+ (NSString *)message {
    CppCounter counter;
    return [NSString stringWithUTF8String:counter.describe().c_str()];
}

@end
