//
//  C01CppBridge.mm
//

#import "C01CppBridge.h"
#include "C01Shape.hpp"

@implementation C01CppBridge

+ (NSString *)probe {
    NSMutableArray *parts = [NSMutableArray array];
    for (const auto &shape : c01MakeShapes()) {
        [parts addObject:[NSString stringWithUTF8String:shape->describe().c_str()]];
    }
    return [parts componentsJoinedByString:@","];
}

@end
