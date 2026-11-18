//
//  NCInjectorTests.m
//  进程内注入：运行时用 clang / swiftc 编出新版本的类与值类型，注入后检查方法是否被替换、布局变化时是否放弃替换
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

/// 本类的 -value 被另一个分类覆盖（老工程里常见的写法）：注入类文件后，分类的覆盖必须保留
@interface NCTOverridden : NSObject
- (NSString *)value;
@end

@implementation NCTOverridden
- (NSString *)value {
    return @"class-v1";
}
@end

@interface NCTOverridden (Override)
@end

@implementation NCTOverridden (Override)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (NSString *)value {
    return @"category";
}
#pragma clang diagnostic pop
@end

/// 先注入一个改了布局的版本，再注入恢复原布局的版本：第二次应正常替换，不再报布局变化
@interface NCTLayoutFlipper : NSObject
- (NSString *)value;
@end

@implementation NCTLayoutFlipper
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
    // 测试结束后删掉临时目录（已加载的 dylib 删除文件不影响使用），否则每跑一次留下几个目录
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    }];
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

- (void)testCategoryOverrideSurvivesClassInjection {
    NSString *source = @"#import <Foundation/Foundation.h>\n"
                       @"@interface NCTOverridden : NSObject @end\n"
                       @"@implementation NCTOverridden\n"
                       @"- (NSString *)value { return @\"class-v2\"; }\n"
                       @"@end\n";
    NSString *dylib = [self compileDylib:source name:@"Overridden"];
    if (!dylib) {
        return;
    }
    NCTOverridden *existing = [NCTOverridden new];
    XCTAssertEqualObjects(existing.value, @"category");
    NCInjectResult *result = [NCInjector injectDylibAtPath:dylib sourceFiles:@[@"/tmp/Overridden.m"]];
    XCTAssertEqual(result.status, NCInjectStatusSuccess, @"%@", result.message);
    // 新实现应写到类自己的那条方法上；排在前面的分类条目不能被改掉
    XCTAssertEqualObjects(existing.value, @"category");
}

- (void)testRestoredLayoutIsReplacedAgain {
    NSString *changed = @"#import <Foundation/Foundation.h>\n"
                        @"@interface NCTLayoutFlipper : NSObject { long _extra[4]; } @end\n"
                        @"@implementation NCTLayoutFlipper\n"
                        @"- (NSString *)value { _extra[3] = 1; return @\"v2\"; }\n"
                        @"@end\n";
    NSString *restored = @"#import <Foundation/Foundation.h>\n"
                         @"@interface NCTLayoutFlipper : NSObject @end\n"
                         @"@implementation NCTLayoutFlipper\n"
                         @"- (NSString *)value { return @\"v3\"; }\n"
                         @"@end\n";
    NSString *changedDylib = [self compileDylib:changed name:@"LayoutFlipperChanged"];
    NSString *restoredDylib = [self compileDylib:restored name:@"LayoutFlipperRestored"];
    if (!changedDylib || !restoredDylib) {
        return;
    }
    NCTLayoutFlipper *existing = [NCTLayoutFlipper new];
    NCInjectResult *first = [NCInjector injectDylibAtPath:changedDylib sourceFiles:@[@"/tmp/LayoutFlipper.m"]];
    XCTAssertTrue([first.layoutChangedClasses containsObject:@"NCTLayoutFlipper"], @"%@", first.layoutChangedClasses);
    XCTAssertEqualObjects(existing.value, @"v1");

    // 布局改回来了：以 App 原有的类为准，历史注入留下的那份布局不同的副本不应让它继续被判为布局变化
    NCInjectResult *second = [NCInjector injectDylibAtPath:restoredDylib sourceFiles:@[@"/tmp/LayoutFlipper.m"]];
    XCTAssertEqual(second.status, NCInjectStatusSuccess, @"%@", second.message);
    XCTAssertEqual(second.layoutChangedClasses.count, 0u, @"%@", second.layoutChangedClasses);
    XCTAssertEqual(second.warnings.count, 0u, @"%@", second.warnings);
    XCTAssertEqualObjects(existing.value, @"v3");
}

/// 用 swiftc 把一段 Swift 源码编成 dylib（模块名固定为 NCTValueApp，带 -interposable 与 -enable-testing，
/// 与 Debug 工程的产物一致）。没有可用的编译器时返回 nil
- (NSString *)compileSwiftDylib:(NSString *)source atPath:(NSString *)dylibPath extraArguments:(NSArray<NSString *> *)extraArguments {
    NSString *dir = dylibPath.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *sourcePath = [dir stringByAppendingPathComponent:@"Values.swift"];
    [source writeToFile:sourcePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = [@[@"swiftc", @"-emit-library", @"-Onone", @"-enable-testing", @"-parse-as-library",
                        @"-module-name", @"NCTValueApp", @"-Xlinker", @"-interposable",
                        sourcePath, @"-o", dylibPath] arrayByAddingObjectsFromArray:extraArguments];
    task.currentDirectoryURL = [NSURL fileURLWithPath:dir];
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

/// 值类型（struct）的布局保护：只改方法体照常替换；加存储属性后整个文件不替换并报布局变化；新增结构体不算变化。
/// 「App」是一个放在 Build/Products 目录下的 Swift dylib（客户端据此把它当作 App 原有镜像），
/// 探针函数 nct_value_probe 留在 App 里充当旧调用方：它按 App 原始布局构造、接收 NCTPoint
- (void)testValueTypeLayoutChangeSkipsWholeImage {
    // 占位符依次是：weight() 的返回表达式、NCTPoint 多出来的存储属性、文件末尾追加的声明
    NSString *template = @"struct NCTPoint {\n"
                         @"    var x: Int\n"
                         @"    var y: Int\n"
                         @"%2$@"
                         @"    init(x: Int, y: Int) {\n"
                         @"        self.x = x\n"
                         @"        self.y = y\n"
                         @"    }\n"
                         @"    func weight() -> Int {\n"
                         @"        return %1$@\n"
                         @"    }\n"
                         @"}\n"
                         @"func nctMakePoint() -> NCTPoint {\n"
                         @"    return NCTPoint(x: 10, y: 20)\n"
                         @"}\n"
                         @"@_cdecl(\"nct_value_probe\")\n"
                         @"public func nctValueProbe() -> Int {\n"
                         @"    return NCTPoint(x: 1, y: 2).weight() + nctMakePoint().x\n"
                         @"}\n"
                         @"%3$@";
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"nocompile-client-tests-%@", NSUUID.UUID.UUIDString]];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    }];
    NSArray<NSString *> *lookup = @[@"-Xlinker", @"-undefined", @"-Xlinker", @"dynamic_lookup"];
    NSString *app = [self compileSwiftDylib:[NSString stringWithFormat:template, @"x + y", @"", @""]
                                     atPath:[root stringByAppendingPathComponent:@"Build/Products/libNCTValueApp.dylib"]
                             extraArguments:@[]];
    NSString *bodyChanged = [self compileSwiftDylib:[NSString stringWithFormat:template, @"(x + y) * 100", @"", @""]
                                             atPath:[root stringByAppendingPathComponent:@"body/Values.dylib"]
                                     extraArguments:lookup];
    // 加了存储属性 z：weight() 与 nctMakePoint() 都按新布局编译，哪个被替换都会让旧调用方读到错的数据
    NSString *fieldAdded = [self compileSwiftDylib:[NSString stringWithFormat:template, @"7777 + z", @"    var z: Int = 5\n", @""]
                                            atPath:[root stringByAppendingPathComponent:@"field/Values.dylib"]
                                    extraArguments:lookup];
    NSString *typeAdded = [self compileSwiftDylib:[NSString stringWithFormat:template, @"x + y + NCTExtra().n", @"",
                                                   @"struct NCTExtra {\n    var n = 5000\n}\n"]
                                           atPath:[root stringByAppendingPathComponent:@"added/Values.dylib"]
                                   extraArguments:lookup];
    if (!app || !bodyChanged || !fieldAdded || !typeAdded) {
        return;
    }
    void *handle = dlopen(app.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    XCTAssertTrue(handle != NULL, @"%s", dlerror());
    long (*probe)(void) = (long (*)(void))dlsym(handle, "nct_value_probe");
    XCTAssertTrue(probe != NULL);
    if (!probe) {
        return;
    }
    XCTAssertEqual(probe(), 13);

    // 只改方法体：照常替换，不报布局变化
    NCInjectResult *body = [NCInjector injectDylibAtPath:bodyChanged sourceFiles:@[@"/tmp/Values.swift"]];
    XCTAssertEqual(body.status, NCInjectStatusSuccess, @"%@", body.message);
    XCTAssertEqual(body.layoutChangedClasses.count, 0u, @"%@", body.layoutChangedClasses);
    XCTAssertEqual(body.warnings.count, 0u, @"%@", body.warnings);
    XCTAssertEqual(probe(), 310);

    // 加存储属性：报布局变化，这个镜像里的实现一个都不替换，旧调用方看到的仍是上一次的结果
    NCInjectResult *field = [NCInjector injectDylibAtPath:fieldAdded sourceFiles:@[@"/tmp/Values.swift"]];
    XCTAssertEqual(field.status, NCInjectStatusSuccess, @"%@", field.message);
    XCTAssertEqualObjects(field.layoutChangedClasses, @[@"NCTValueApp.NCTPoint"]);
    XCTAssertEqual(field.symbolsRebound, 0u);
    XCTAssertEqual(field.warnings.count, 1u, @"%@", field.warnings);
    XCTAssertEqual(probe(), 310);

    // 布局改回来并新增一个结构体：以 App 原有的布局为准，照常替换；新增的类型不算变化
    NCInjectResult *added = [NCInjector injectDylibAtPath:typeAdded sourceFiles:@[@"/tmp/Values.swift"]];
    XCTAssertEqual(added.status, NCInjectStatusSuccess, @"%@", added.message);
    XCTAssertEqual(added.layoutChangedClasses.count, 0u, @"%@", added.layoutChangedClasses);
    XCTAssertEqual(added.warnings.count, 0u, @"%@", added.warnings);
    XCTAssertEqual(probe(), 5013);
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
