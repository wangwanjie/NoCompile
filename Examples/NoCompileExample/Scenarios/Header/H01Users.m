//
//  H01Users.m
//  场景 H01 / H01b：引用本工程宏头文件、framework 宏头文件的 ObjC 实现
//

#import "H01Macros.h"
#import <ExCore/ExCore.h>
#import "H01Users.h"

@implementation H01Users

+ (NSString *)appMacroText {
    return [NSString stringWithFormat:@"app:%s", H01_TOKEN];
}

+ (NSString *)frameworkMacroText {
    return [NSString stringWithFormat:@"fw:%@", EX_HEADER_TOKEN];
}

+ (NSString *)frameworkInlineText {
    return [NSString stringWithFormat:@"fw:%@", ExInlineGreeting()];
}

+ (NSString *)probe {
    return [NSString stringWithFormat:@"%@ %@ %@ %@ %@", [self appMacroText], [self frameworkMacroText], [self frameworkInlineText],
            [ExHeaderUser macroText], [ExHeaderUser inlineText]];
}

@end
