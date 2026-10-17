//
//  H02InlineUser.m
//

#import <Foundation/Foundation.h>
#import "H02Inline.h"
#import "H02InlineUser.h"

@implementation H02InlineUser

+ (NSString *)probe {
    return [NSString stringWithFormat:@"%s c=%d", h02_inline_text(), h02_clamp(50, 0, 10)];
}

@end
