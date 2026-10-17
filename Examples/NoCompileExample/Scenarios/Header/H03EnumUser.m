//
//  H03EnumUser.m
//

#import "H03Enums.h"
#import "H03EnumUser.h"

@implementation H03EnumUser

+ (NSString *)probe {
    return [NSString stringWithFormat:@"H03 kind=%ld limit=%d", (long)H03KindB, H03_LIMIT];
}

@end
