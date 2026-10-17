//
//  Target_Player.m
//

#import "Target_Player.h"

@implementation Target_Player

- (NSString *)Action_info:(NSDictionary *)params {
    return [NSString stringWithFormat:@"Player(@@v1@@):%@", params[@"k"]];
}

@end
