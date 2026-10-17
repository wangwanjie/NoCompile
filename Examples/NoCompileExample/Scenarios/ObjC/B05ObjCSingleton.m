//
//  B05ObjCSingleton.m
//  场景 B05：dispatch_once 单例 + 文件内 static 变量。重新注入后单例实例、static 计数必须保留
//

#import "B05ObjCSingleton.h"

static NSInteger gB05Counter = 0;
static NSString *gB05Name = nil;

@implementation B05ObjCSingleton

+ (instancetype)sharedInstance {
    static B05ObjCSingleton *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[B05ObjCSingleton alloc] init];
        gB05Name = @"singleton";
    });
    return instance;
}

+ (NSString *)probe {
    B05ObjCSingleton *shared = [self sharedInstance];
    shared.hits += 1;
    gB05Counter += 1;
    return [NSString stringWithFormat:@"B05(@@v1@@) hits=%ld n=%ld name=%@", (long)shared.hits, (long)gB05Counter, gB05Name];
}

@end
