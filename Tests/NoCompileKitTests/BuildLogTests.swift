//
//  BuildLogTests.swift
//  构建日志明文解析：Swift driver / clang / ibtool / 资源拷贝 / 签名身份，以及多平台多架构的取舍
//

import XCTest
@testable import NoCompileKit

final class BuildLogTests: XCTestCase {

    /// 不存在的目录，规范化路径时不会被符号链接改写
    private let root = "/NoCompileTests/Proj"

    private func swiftDriver(module: String, target: String, files: [String]) -> String {
        let sources = files.map { "\(root)/\($0)" }.joined(separator: " ")
        return "builtin-SwiftDriver -- /usr/bin/swiftc -module-name \(module) -target \(target) \(sources)"
    }

    private func clang(_ file: String, target: String, extra: String = "") -> String {
        return "/Toolchains/usr/bin/clang -x objective-c -target \(target) \(extra) -c \(root)/\(file) -o /DD/Foo.build/Objects-normal/arm64/x.o"
    }

    // MARK: - 平台与架构

    func testPlatformForTarget() {
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-ios15.0-simulator"), "iphonesimulator")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-ios15.0"), "iphoneos")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-macos12.0"), "macosx")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-ios15.0-macabi"), "maccatalyst")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-watchos9.0-simulator"), "watchsimulator")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-watchos9.0"), "watchos")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-xros1.0"), "xros")
        // tvOS 客户端与 iOS 客户端上报相同的平台名（simulator / device），命令须归到 iOS 一类才能被选中
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-tvos15.0-simulator"), "iphonesimulator")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: "arm64-apple-tvos15.0"), "iphoneos")
        XCTAssertEqual(RawCompileCommand.platform(forTarget: nil), "unknown")
    }

    func testArchForTarget() {
        XCTAssertEqual(RawCompileCommand.arch(forTarget: "x86_64-apple-ios15.0-simulator"), "x86_64")
        XCTAssertEqual(RawCompileCommand.arch(forTarget: "arm64e-apple-macos12"), "arm64e")
        XCTAssertNil(RawCompileCommand.arch(forTarget: nil))
        XCTAssertNil(RawCompileCommand.arch(forTarget: ""))
    }

    func testPlatformOfProductPath() {
        XCTAssertEqual(ParsedCommands.platformOfProductPath("/DD/Build/Products/Debug-iphonesimulator/A.app/x.png"), "iphonesimulator")
        XCTAssertEqual(ParsedCommands.platformOfProductPath("/DD/Build/Products/Debug/A.app/Contents/x.png"), "macosx")
        XCTAssertEqual(ParsedCommands.platformOfProductPath("/DD/Build/Intermediates.noindex/UninstalledProducts/iphoneos/A.framework"), "iphoneos")
        XCTAssertNil(ParsedCommands.platformOfProductPath("/somewhere/else"))
        // 带连字符的自定义配置名（macOS 无平台后缀）
        XCTAssertEqual(ParsedCommands.platformOfProductPath("/DD/Build/Products/Debug-Staging/A.app/x.png"), "macosx")
        XCTAssertEqual(ParsedCommands.platformOfProductPath("/DD/Build/Products/Debug-appletvsimulator/A.app/x.png"), "iphonesimulator")
    }

    // MARK: - 日志解析

    func testParsesSwiftModulesPerPlatformAndArch() {
        let log = [
            swiftDriver(module: "App", target: "arm64-apple-ios15.0-simulator", files: ["A.swift"]),
            swiftDriver(module: "App", target: "x86_64-apple-ios15.0-simulator", files: ["A.swift"]),
            swiftDriver(module: "App", target: "arm64-apple-ios15.0", files: ["A.swift"]),
            // 同一 (模块, 平台, 架构) 的旧命令被忽略：日志新的在前
            swiftDriver(module: "App", target: "arm64-apple-ios15.0-simulator", files: ["Old.swift"]),
        ].joined(separator: "\r")
        let parsed = BuildLog.parse(plainText: log)
        XCTAssertEqual(parsed.swiftModules.count, 3)

        let sim = parsed.swiftModules(for: "iphonesimulator")
        XCTAssertEqual(sim.count, 1, "每个模块只返回一条")
        XCTAssertEqual(sim.first?.arch, "arm64", "默认取最新的一条")
        XCTAssertEqual(parsed.swiftModules(for: "iphonesimulator", arch: "x86_64").first?.arch, "x86_64")
        XCTAssertEqual(parsed.swiftModules(for: "iphoneos").first?.moduleName, "App")
        XCTAssertTrue(ParsedCommands.swiftSources(of: sim[0]).contains("\(root)/A.swift"))
    }

    func testParsesClangCommandsAndWorkingDirectory() {
        let log = [
            "cd \(root)",
            clang("B.m", target: "arm64-apple-ios15.0-simulator"),
            clang("B.m", target: "x86_64-apple-ios15.0-simulator"),
            clang("B.m", target: "arm64-apple-ios15.0-simulator", extra: "-DOLD"),
        ].joined(separator: "\n")
        let parsed = BuildLog.parse(plainText: log)
        let command = parsed.clangCommand(for: "\(root)/B.m", platform: "iphonesimulator")
        XCTAssertEqual(command?.workingDirectory, root)
        XCTAssertEqual(command?.arch, "arm64")
        XCTAssertFalse(command?.tokens.contains("-DOLD") ?? true, "同架构只保留最新一条")
        XCTAssertEqual(parsed.clangCommand(for: "\(root)/B.m", platform: "iphonesimulator", arch: "x86_64")?.arch, "x86_64")
        XCTAssertNil(parsed.clangCommand(for: "\(root)/B.m", platform: "iphoneos"))
        XCTAssertEqual(parsed.clangFileCount, 1)
    }

    func testIgnoresWrappedClangLines() {
        let log = "builtin-ScanDependencies -o /x.scan -- /usr/bin/clang -target arm64-apple-macos12 -c \(root)/C.m"
        XCTAssertTrue(BuildLog.parse(plainText: log).clangFiles.isEmpty)
    }

    func testIgnoresNonSourceCompileInputs() {
        let log = "/usr/bin/clang -target arm64-apple-macos12 -c \(root)/Shader.metal -o x.o"
        XCTAssertTrue(BuildLog.parse(plainText: log).clangFiles.isEmpty)
    }

    func testSigningIdentityPrefersCodesignOverExpanded() {
        let log = [
            "export EXPANDED_CODE_SIGN_IDENTITY=AAAA",
            "/usr/bin/codesign --force --sign \"Apple Development: Me\" --timestamp\\=none /x.app",
            "/usr/bin/codesign --force --sign - /y.app",
        ].joined(separator: "\r")
        XCTAssertEqual(BuildLog.parse(plainText: log).signingIdentity, "Apple Development: Me")
        XCTAssertEqual(BuildLog.parse(plainText: "export EXPANDED_CODE_SIGN_IDENTITY=BBBB").signingIdentity, "BBBB")
        XCTAssertNil(BuildLog.parse(plainText: "/usr/bin/codesign --force --sign - /y.app").signingIdentity)
    }

    func testIBToolAndResourceDestinations() {
        let products = "/DD/Build/Products/Debug-iphonesimulator/App.app"
        let log = [
            "/Xcode/usr/bin/ibtool --module App --compile \(products)/Main.storyboardc \(root)/Main.storyboard",
            "/Xcode/usr/bin/ibtool --link \(products) /DD/Main.storyboardc",
            "builtin-copy -exclude .DS_Store \(root)/data.json \(products)",
            "/Xcode/usr/bin/actool --output-format human \(root)/Assets.xcassets --compile \(products)",
            "builtin-copy \(root)/macdata.json /DD/Build/Products/Debug/MacApp.app/Contents/Resources",
        ].joined(separator: "\r")
        let parsed = BuildLog.parse(plainText: log)
        XCTAssertEqual(parsed.ibtoolCommand(for: "\(root)/Main.storyboard")?.moduleName, "App")
        XCTAssertEqual(parsed.resourceDestinations["\(root)/data.json"], "\(products)/data.json")
        XCTAssertEqual(parsed.resourceDestinations["\(root)/Assets.xcassets"], products)
        XCTAssertEqual(parsed.platformResourceDestinations?["macosx"]?["\(root)/macdata.json"],
                       "/DD/Build/Products/Debug/MacApp.app/Contents/Resources/macdata.json")
        let scoped = parsed.scopingResources(to: "macosx")
        XCTAssertNil(scoped.resourceDestinations["\(root)/data.json"], "切到 macOS 视角后不应看到 iOS 的资源")
    }

    // MARK: - 合并与查询

    func testMergingPrefersNewer() {
        let newer = BuildLog.parse(plainText: clang("B.m", target: "arm64-apple-macos12", extra: "-DNEW"))
        let older = BuildLog.parse(plainText: [
            clang("B.m", target: "arm64-apple-macos12", extra: "-DOLD"),
            clang("B.m", target: "x86_64-apple-macos12"),
            clang("C.m", target: "arm64-apple-macos12"),
            "export EXPANDED_CODE_SIGN_IDENTITY=OLDID",
        ].joined(separator: "\r"))
        let merged = newer.merging(older: older)
        XCTAssertTrue(merged.clangCommand(for: "\(root)/B.m", platform: "macosx", arch: "arm64")?.tokens.contains("-DNEW") ?? false)
        XCTAssertNotNil(merged.clangCommand(for: "\(root)/B.m", platform: "macosx", arch: "x86_64"))
        XCTAssertNotNil(merged.clangCommand(for: "\(root)/C.m", platform: "macosx"))
        XCTAssertEqual(merged.signingIdentity, "OLDID")
    }

    func testIsOnlyBuiltForOtherPlatforms() {
        let parsed = BuildLog.parse(plainText: [
            clang("Mac.m", target: "arm64-apple-macos12"),
            swiftDriver(module: "MacApp", target: "arm64-apple-macos12", files: ["Mac.swift"]),
        ].joined(separator: "\r"))
        XCTAssertTrue(parsed.isOnlyBuiltForOtherPlatforms("\(root)/Mac.m", platform: "iphonesimulator"))
        XCTAssertFalse(parsed.isOnlyBuiltForOtherPlatforms("\(root)/Mac.m", platform: "macosx"))
        XCTAssertTrue(parsed.isOnlyBuiltForOtherPlatforms("\(root)/Mac.swift", platform: "iphonesimulator"))
        XCTAssertFalse(parsed.isOnlyBuiltForOtherPlatforms("\(root)/New.m", platform: "iphonesimulator"), "日志里没有的文件按新增文件处理")
    }

    func testClangTemplatePrefersSameLanguageAndNearestDirectory() {
        let parsed = BuildLog.parse(plainText: [
            clang("Feature/Sub/A.m", target: "arm64-apple-macos12"),
            clang("Feature/Sub/B.cpp", target: "arm64-apple-macos12"),
            clang("Other/C.m", target: "arm64-apple-macos12"),
        ].joined(separator: "\r"))
        XCTAssertEqual(parsed.clangTemplate(for: "\(root)/Feature/Sub/New.m", platform: "macosx")?.source, "\(root)/Feature/Sub/A.m")
        XCTAssertEqual(parsed.clangTemplate(for: "\(root)/Feature/Sub/New.cpp", platform: "macosx")?.source, "\(root)/Feature/Sub/B.cpp")
        XCTAssertNil(parsed.clangTemplate(for: "\(root)/Feature/Sub/New.m", platform: "iphoneos"))
    }

    func testDroppingSynthesized() {
        var parsed = BuildLog.parse(plainText: clang("A.m", target: "arm64-apple-macos12"))
        let key = ParsedCommands.clangKey(platform: "macosx", source: "\(root)/A.m")
        var fake = parsed.clangFiles[key]![0]
        fake.synthesized = true
        parsed.clangFiles["macosx|\(root)/S.m"] = [fake]
        let real = parsed.droppingSynthesized()
        XCTAssertNotNil(real.clangFiles[key])
        XCTAssertNil(real.clangFiles["macosx|\(root)/S.m"])
    }

    func testCodableRoundTrip() throws {
        let parsed = BuildLog.parse(plainText: [
            swiftDriver(module: "App", target: "arm64-apple-macos12", files: ["A.swift"]),
            clang("B.m", target: "arm64-apple-macos12"),
        ].joined(separator: "\r"))
        let data = try JSONEncoder().encode(parsed)
        let decoded = try JSONDecoder().decode(ParsedCommands.self, from: data)
        XCTAssertEqual(decoded.swiftModules.count, 1)
        XCTAssertEqual(decoded.clangFiles.count, 1)
    }

    // MARK: - 辅助函数

    func testClangLanguageAndDirectoryDepth() {
        XCTAssertEqual(ParsedCommands.clangLanguage(forPath: "/a/x.M"), "objective-c")
        XCTAssertEqual(ParsedCommands.clangLanguage(forPath: "/a/x.mm"), "objective-c++")
        XCTAssertEqual(ParsedCommands.clangLanguage(forPath: "/a/x.c"), "c")
        XCTAssertEqual(ParsedCommands.clangLanguage(forPath: "/a/x.cc"), "c++")
        XCTAssertEqual(ParsedCommands.commonDirectoryDepth("/a/b/c/x.m", "/a/b/d/y.m"), 2)
        XCTAssertEqual(ParsedCommands.commonDirectoryDepth("/a/x.m", "/b/y.m"), 0)
    }

    func testClangPrimarySource() {
        XCTAssertEqual(BuildLog.clangPrimarySource(in: ["clang", "-c", "/a/b.cpp"]), "/a/b.cpp")
        XCTAssertNil(BuildLog.clangPrimarySource(in: ["clang", "-c", "/a/b.s"]))
        XCTAssertNil(BuildLog.clangPrimarySource(in: ["clang", "-c"]))
    }

    func testLineSplitterHandlesChunkBoundaries() {
        let text = Array("first\r\nsecond\rthird".utf8)
        var lines: [String] = []
        var carry: [UInt8] = []
        // 分三块送入，块边界落在行中间
        for range in [0 ..< 3, 3 ..< 9, 9 ..< text.count] {
            Array(text[range]).withUnsafeBufferPointer { chunk in
                LineSplitter.split(chunk, carry: &carry) { lines.append(String(decoding: $0, as: UTF8.self)) }
            }
        }
        carry.withUnsafeBufferPointer { lines.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(lines, ["first", "second", "third"])
    }

    func testTargetSourceRoots() {
        let parsed = BuildLog.parse(plainText: [
            clang("Feature/A/x.m", target: "arm64-apple-macos12"),
            clang("Feature/B/y.m", target: "arm64-apple-macos12"),
        ].joined(separator: "\r"))
        let roots = TargetSourceRoots(commands: parsed)
        XCTAssertTrue(roots.isKnown("\(root)/Feature/A/x.m"))
        XCTAssertTrue(roots.belongsToTarget("\(root)/Feature/C/new.m"), "同一目标源码根目录内的新文件属于该目标")
        XCTAssertFalse(roots.belongsToTarget("/NoCompileTests/Elsewhere/z.m"))
    }
}
