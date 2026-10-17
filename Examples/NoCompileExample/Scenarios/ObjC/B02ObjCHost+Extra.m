//
//  B02ObjCHost+Extra.m
//  场景 B02：自有类的分类（只含分类的 .m）。分类方法在 dlopen 时由 runtime 挂到宿主类上
//

#import "B02ObjCHost+Extra.h"

@implementation B02ObjCHost (Extra)

- (NSString *)extraName {
    return @"extra(@@v1@@)";
}

@end
