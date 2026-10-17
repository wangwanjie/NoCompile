//
//  B04ObjCBlocks.m
//  场景 B04：block 属性 / 回调 / GCD 同步
//

#import "B04ObjCBlocks.h"

@implementation B04ObjCBlocks

+ (void)enumerateWithCompletion:(void (^)(NSString *result))completion {
    NSString *base = @"B04(@@v1@@)";
    completion(base);
}

+ (NSString *)probe {
    B04ObjCBlocks *obj = [B04ObjCBlocks new];
    obj.formatter = ^NSString *(NSInteger value) {
        return [NSString stringWithFormat:@"f%ld", (long)value];
    };
    __block NSString *captured = nil;
    [self enumerateWithCompletion:^(NSString *result) {
        captured = result;
    }];
    __block NSString *queued = nil;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        queued = obj.formatter(7);
    });
    return [NSString stringWithFormat:@"%@ %@", captured, queued];
}

@end
