//
//  NCBoot.m
//  自动启动：镜像加载后在 +load 中拉起客户端
//
//  SPM / 静态库方式接入时，无需在 App 代码里写任何调用。
//  通过 XCODE_RUNNING_FOR_PREVIEWS、单元测试等环境变量判断是否应跳过。
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NoCompile.h"
#import <Foundation/Foundation.h>

@interface NCBoot : NSObject
@end

@implementation NCBoot

+ (void)load {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;

        // SwiftUI Preview 环境下不启动
        if ([env[@"XCODE_RUNNING_FOR_PREVIEWS"] isEqualToString:@"1"]) {
            return;
        }
        // 单元测试环境下默认不启动（除非显式开启）
        if (env[@"XCTestConfigurationFilePath"] != nil && env[@"NOCOMPILE_ENABLE_IN_TESTS"] == nil) {
            return;
        }
        // 显式禁用
        if ([env[@"NOCOMPILE_DISABLE"] isEqualToString:@"1"]) {
            return;
        }

        NSString *host = env[@"NOCOMPILE_HOST"];
        // 延后到启动完成，避免干扰 App 自身的初始化
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host.length > 0) {
                [NoCompile startWithHost:host];
            } else {
                [NoCompile start];
            }
        });
    }
}

@end

#endif
