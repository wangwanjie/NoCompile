//
//  C04CBridge.m
//

#import "C04CBridge.h"
#import "C04CPlain.h"

@implementation C04CBridge

+ (NSString *)probe {
    C04Size size = c04_make_size(3, 4);
    return [NSString stringWithFormat:@"%s %dx%d %s sum=%d apply=%d", c04_describe(), size.width, size.height, size.label,
            c04_sum(3, 1, 2, 3), c04_apply(c04_double, 21)];
}

@end
