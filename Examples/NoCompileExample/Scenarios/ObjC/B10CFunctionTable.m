//
//  B10CFunctionTable.m
//  场景 B10：static C 函数、函数指针表（数据段里的函数地址）、const 数组
//

#import "B10CFunctionTable.h"

typedef const char *(*B10Handler)(void);

static const char *B10First(void) {
    return "first(@@v1@@)";
}

static const char *B10Second(void) {
    return "second";
}

/// 函数指针表：表里存的是函数地址，重新注入后调用方仍应拿到新函数
static const B10Handler kB10Handlers[] = {B10First, B10Second};

static const char *const kB10Names[] = {"one", "two"};

@implementation B10CFunctionTable

+ (NSString *)probe {
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        [parts addObject:[NSString stringWithFormat:@"%s=%s", kB10Names[i], kB10Handlers[i]()]];
    }
    return [parts componentsJoinedByString:@","];
}

@end
