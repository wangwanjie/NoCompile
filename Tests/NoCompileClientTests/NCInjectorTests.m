//
//  NCInjectorTests.m
//  进程内注入：运行时用 clang 编出新版本的类，注入后检查方法是否被替换、布局变化时是否放弃替换
//

#import <XCTest/XCTest.h>
#import "NCInjector.h"
#import "NCMachO.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>

/// 被热重载的类：注入后 greeting 应返回新实现的值
@interface NCTGreeter : NSObject
- (NSString *)greeting;
+ (NSString *)classGreeting;
@end

@implementation NCTGreeter
- (NSString *)greeting {
    return @"v1";
}
+ (NSString *)classGreeting {
    return @"class-v1";
}
@end

/// 由后台线程发起注入的类
@interface NCTBackgroundGreeter : NSObject
- (NSString *)greeting;
@end

@implementation NCTBackgroundGreeter
- (NSString *)greeting {
    return @"bg-v1";
}
@end

/// 新版本的类符号是局部符号（-fvisibility=hidden / EXPORTED_SYMBOLS_FILE 的效果），dlsym 查不到
@interface NCTHiddenGreeter : NSObject
- (NSString *)greeting;
@end

@implementation NCTHiddenGreeter
- (NSString *)greeting {
    return @"hidden-v1";
}
@end

/// 新版本增加了实例变量（内存布局变化）：为避免越界读写，注入时不能替换它的方法
@interface NCTLayoutChanger : NSObject
- (NSString *)value;
@end

@implementation NCTLayoutChanger
- (NSString *)value {
    return @"v1";
}
@end

@interface NCInjectorTests : XCTestCase
@end

@implementation NCInjectorTests

/// 用 clang 把一段 ObjC 源码编成 dylib，返回路径；没有可用的编译器时跳过测试
- (NSString *)compileDylib:(NSString *)source name:(NSString *)name {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"nocompile-client-tests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *sourcePath = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".m"]];
    NSString *dylibPath = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".dylib"]];
    [source writeToFile:sourcePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"clang", @"-dynamiclib", @"-fobjc-arc", @"-framework", @"Foundation",
                       @"-undefined", @"dynamic_lookup", sourcePath, @"-o", dylibPath];
    NSPipe *pipe = [NSPipe pipe];
    task.standardError = pipe;
    task.standardOutput = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return nil;
    }
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        XCTFail(@"编译失败：%@", [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]);
        return nil;
    }
    return dylibPath;
}

- (void)testObjCMethodsAreReplaced {
    NSString *source = @"#import <Foundation/Foundation.h>\n"
                       @"@interface NCTGreeter : NSObject @end\n"
                       @"@implementation NCTGreeter\n"
                       @"- (NSString *)greeting { return @\"v2\"; }\n"
                       @"+ (NSString *)classGreeting { return @\"class-v2\"; }\n"
                       @"@end\n";
    NSString *dylib = [self compileDylib:source name:@"Greeter"];
    if (!dylib) {
        return;
    }
    NCTGreeter *existing = [NCTGreeter new];
    XCTAssertEqualObjects(existing.greeting, @"v1");

    NCInjectResult *result = [NCInjector injectDylibAtPath:dylib sourceFiles:@[@"/tmp/Greeter.m"]];
    XCTAssertEqual(result.status, NCInjectStatusSuccess, @"%@", result.message);
    XCTAssertGreaterThanOrEqual(result.objcMethodsReplaced, 2u);
    // 已存在的实例与类方法都用上新实现
    XCTAssertEqualObjects(existing.greeting, @"v2");
    XCTAssertEqualObjects(NCTGreeter.classGreeting, @"class-v2");
    // 注入后新旧类视为同一个类
    XCTAssertTrue([existing isKindOfClass:NSClassFromString(@"NCTGreeter")]);
}

- (void)testHiddenClassSymbolIsStillReplaced {
    NSString *source = @"#import <Foundation/Foundation.h>\n"
                       @"__attribute__((visibility(\"hidden\"))) @interface NCTHiddenGreeter : NSObject @end\n"
                       @"@implementation NCTHiddenGreeter\n"
                       @"- (NSString *)greeting { return @\"hidden-v2\"; }\n"
                       @"@end\n";
    NSString *dylib = [self compileDylib:source name:@"HiddenGreeter"];
    if (!dylib) {
        return;
    }
    NCTHiddenGreeter *existing = [NCTHiddenGreeter new];
    NCInjectResult *result = [NCInjector injectDylibAtPath:dylib sourceFiles:@[@"/tmp/HiddenGreeter.m"]];
    XCTAssertEqual(result.status, NCInjectStatusSuccess, @"%@", result.message);
    XCTAssertEqualObjects(existing.greeting, @"hidden-v2");
}

- (void)testInjectFromBackgroundThread {
    NSString *source = @"#import <Foundation/Foundation.h>\n"
                       @"@interface NCTBackgroundGreeter : NSObject @end\n"
                       @"@implementation NCTBackgroundGreeter\n"
                       @"- (NSString *)greeting { return @\"bg-v2\"; }\n"
                       @"@end\n";
    NSString *dylib = [self compileDylib:source name:@"GreeterBackground"];
    if (!dylib) {
        return;
    }
    // 后台线程发起注入：实际替换切到主线程执行，主线程此时在等待 expectation（run loop 运转），不应死锁
    XCTestExpectation *done = [self expectationWithDescription:@"注入完成"];
    __block NCInjectResult *result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        result = [NCInjector injectDylibAtPath:dylib sourceFiles:@[@"/tmp/GreeterBackground.m"]];
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:30];
    XCTAssertEqual(result.status, NCInjectStatusSuccess, @"%@", result.message);
    XCTAssertEqualObjects([NCTBackgroundGreeter new].greeting, @"bg-v2");
}

- (void)testLayoutChangeSkipsReplacement {
    NSString *source = @"#import <Foundation/Foundation.h>\n"
                       @"@interface NCTLayoutChanger : NSObject { long _extra[4]; } @end\n"
                       @"@implementation NCTLayoutChanger\n"
                       @"- (NSString *)value { _extra[3] = 1; return @\"v2\"; }\n"
                       @"@end\n";
    NSString *dylib = [self compileDylib:source name:@"LayoutChanger"];
    if (!dylib) {
        return;
    }
    NCTLayoutChanger *existing = [NCTLayoutChanger new];
    NCInjectResult *result = [NCInjector injectDylibAtPath:dylib sourceFiles:@[@"/tmp/LayoutChanger.m"]];
    XCTAssertTrue([result.layoutChangedClasses containsObject:@"NCTLayoutChanger"], @"%@", result.layoutChangedClasses);
    // 旧实例按旧布局分配，新实现写 _extra 会越界，所以必须保留旧实现
    XCTAssertEqualObjects(existing.value, @"v1");
}

- (void)testMissingDylibReportsLoadFailure {
    NCInjectResult *result = [NCInjector injectDylibAtPath:@"/nonexistent/nocompile.dylib" sourceFiles:nil];
    XCTAssertEqual(result.status, NCInjectStatusLoadFailed);
    XCTAssertGreaterThan(result.message.length, 0u);
}

- (void)testMachOSymbolEnumerationFindsTestClass {
    Dl_info info;
    XCTAssertTrue(dladdr((__bridge const void *)NCTGreeter.class, &info));
    NCImage *image = NCImageForPath(@(info.dli_fname));
    XCTAssertNotNil(image);
    __block BOOL found = NO;
    NCEnumerateSymbols(image, ^(const char *name, uintptr_t address, uint8_t type, const struct section_64 *section, BOOL *stop) {
        if (strcmp(name, "_OBJC_CLASS_$_NCTGreeter") == 0) {
            found = YES;
            *stop = YES;
        }
    });
    XCTAssertTrue(found);
    XCTAssertTrue(NCImageContainsAddress(image, (__bridge const void *)NCTGreeter.class));
    XCTAssertFalse(NCImageContainsAddress(image, (const void *)&strcmp));
}

@end
