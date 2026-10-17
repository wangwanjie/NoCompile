//
//  B02ObjCHost.m
//  场景 B02（宿主类部分）
//

#import "B02ObjCHost.h"
#import "B02ObjCHost+Extra.h"

@implementation B02ObjCHost

- (NSString *)hostName {
    return @"host";
}

+ (NSString *)probe {
    B02ObjCHost *host = [B02ObjCHost new];
    return [NSString stringWithFormat:@"%@ %@", [host hostName], [host extraName]];
}

@end
