//
//  C02TemplateUser.mm
//  场景 C02：使用头文件模板的 ObjC++ 类
//

#import <Foundation/Foundation.h>
#include "C02Template.hpp"

@interface C02TemplateUser : NSObject
+ (NSString *)probe;
@end

@implementation C02TemplateUser

+ (NSString *)probe {
    C02Cache<std::string, int> cache;
    cache.put("a", 1);
    return [NSString stringWithFormat:@"%s a=%d b=%d", C02Cache<std::string, int>::tag().c_str(),
            cache.get("a", -1), cache.get("b", -1)];
}

@end
