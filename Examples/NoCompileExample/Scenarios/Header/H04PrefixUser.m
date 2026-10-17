//
//  H04PrefixUser.m
//  场景 H04：不显式 import，宏来自 PCH
//

#import "H04PrefixUser.h"

@implementation H04PrefixUser

+ (NSString *)probe {
    return [NSString stringWithFormat:@"H04 %@", EX_PREFIX_TOKEN];
}

@end
