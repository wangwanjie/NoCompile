//
//  C05ObjCpp.mm
//  场景 C05：ObjC++ 混用：C++ lambda 捕获 ObjC 对象、std::function、ARC 对象放进 std::vector
//

#import <Foundation/Foundation.h>
#include <functional>
#include <vector>

@interface C05ObjCpp : NSObject
+ (NSString *)probe;
@end

@implementation C05ObjCpp

+ (NSString *)probe {
    NSString *token = @"C05(@@v1@@)";
    std::function<NSString *(NSInteger)> formatter = [token](NSInteger value) {
        return [NSString stringWithFormat:@"%@:%ld", token, (long)value];
    };
    std::vector<NSString *> items;
    items.push_back(formatter(1));
    items.push_back(formatter(2));
    return [NSString stringWithFormat:@"%@|%@", items[0], items[1]];
}

@end
