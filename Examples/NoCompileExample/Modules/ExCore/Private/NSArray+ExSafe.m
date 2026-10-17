//
//  NSArray+ExSafe.m
//  场景 B03：系统类的分类，位于 framework 内（只含分类的 .m）
//

#import <ExCore/NSArray+ExSafe.h>

@implementation NSArray (ExSafe)

- (id)kg_safeObjectAtIndex:(NSUInteger)index {
    if (index >= self.count) {
        return nil;
    }
    return self[index];
}

- (NSString *)kg_safeDescription {
    return [NSString stringWithFormat:@"ExSafe:@@v1@@ count=%lu", (unsigned long)self.count];
}

@end
