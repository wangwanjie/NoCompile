//
//  NSString+ExPath.m
//

#import <ExCore/NSString+ExPath.h>

@implementation NSString (ExPath)

- (NSString *)kg_lastPathToken {
    return [NSString stringWithFormat:@"%@#@@v1@@", self.lastPathComponent];
}

@end
