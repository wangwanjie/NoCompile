//
//  S09NewObjCClassHost.m
//  场景 S09：运行中新建一个 ObjC 类文件（.h/.m），已有文件按名字动态使用它
//

#import <Foundation/Foundation.h>

@interface S09Host : NSObject
+ (NSString *)probe;
@end

@implementation S09Host

+ (NSString *)probe {
    Class cls = NSClassFromString(@"S09NewClass");
    if (cls == Nil) {
        return @"S09 no-class";
    }
    return [cls performSelector:NSSelectorFromString(@"text")];
}

@end
