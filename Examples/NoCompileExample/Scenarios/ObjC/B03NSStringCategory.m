//
//  B03NSStringCategory.m
//

#import "B03NSStringCategory.h"

@implementation NSString (B03Tools)

- (NSString *)kg_b03Tag {
    return [NSString stringWithFormat:@"B03(@@v1@@):%@", self];
}

@end

@implementation B03Probe

+ (NSString *)probe {
    return [@"str" kg_b03Tag];
}

@end
