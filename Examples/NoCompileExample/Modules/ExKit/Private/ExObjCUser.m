//
//  ExObjCUser.m
//  场景 M06：ObjC → Swift（同 framework 内混编）
//

#import <ExKit/ExObjCUser.h>
#import <ExKit/ExKit-Swift.h>

@implementation ExObjCUser

+ (NSString *)callSwift {
    return [NSString stringWithFormat:@"ObjC(@@v1@@)->%@", [ExSwiftBridge swiftText]];
}

@end
