//
//  ObjCBaseWidget.m
//

#import "ObjCBaseWidget.h"

@implementation ObjCBaseWidget

- (NSString *)title {
    return @"base-title";
}

- (NSString *)renderBody {
    return [@"objc-body:" stringByAppendingString:[self title]];
}

@end
