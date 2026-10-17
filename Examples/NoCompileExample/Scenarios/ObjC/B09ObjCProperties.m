//
//  B09ObjCProperties.m
//  场景 B09：自定义 setter / getter、KVO 观察、readonly 计算属性
//

#import "B09ObjCProperties.h"

@implementation B09ObjCProperties

- (void)setTitle:(NSString *)title {
    _title = [title stringByAppendingString:@"@@v1@@"];
}

- (NSInteger)doubled {
    return self.count * 2;
}

+ (NSString *)probe {
    B09ObjCProperties *object = [B09ObjCProperties new];
    NSMutableArray *seen = [NSMutableArray array];
    [object addObserver:(id)object forKeyPath:@"title" options:0 context:NULL];
    object.title = @"t";
    [object removeObserver:(id)object forKeyPath:@"title"];
    object.count = 4;
    [seen addObject:object.title];
    return [NSString stringWithFormat:@"B09 %@ d=%ld", seen.firstObject, (long)object.doubled];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
}

@end
