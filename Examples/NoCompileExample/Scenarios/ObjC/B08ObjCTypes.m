//
//  B08ObjCTypes.m
//  场景 B08：NS_ENUM / NS_OPTIONS / 协议 / delegate / 轻量级泛型
//

#import "B08ObjCTypes.h"

@implementation B08ObjCTypes

- (NSString *)handle:(B08Kind)kind {
    return [NSString stringWithFormat:@"B08(@@v1@@):kind=%ld", (long)kind];
}

+ (NSString *)probe {
    B08ObjCTypes *object = [B08ObjCTypes new];
    object.delegate = object;
    object.names = @[@"a", @"b"];
    object.scores = @{@"x": @1};
    B08Flags flags = B08FlagsHD | B08FlagsVIP;
    return [NSString stringWithFormat:@"%@ f=%lu n=%lu s=%@", [object.delegate handle:B08KindAlbum],
            (unsigned long)flags, (unsigned long)object.names.count, object.scores[@"x"]];
}

@end
