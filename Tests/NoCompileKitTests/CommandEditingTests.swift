//
//  CommandEditingTests.swift
//  clang 命令编辑、预编译头识别、构建清单解析、签名身份与依赖文件解析
//

import XCTest
@testable import NoCompileKit

final class CommandEditingTests: XCTestCase {

    private let xcodeCommand = [
        "/usr/bin/clang", "-x", "objective-c", "-target", "arm64-apple-ios15.0-simulator",
        "@/DD/App.build/Objects-normal/arm64/7187679823f38a2a940e0043cdf9d637-common-args.resp",
        "-fno-objc-arc", "-Wno-unused",
        "-include", "/DD/PrefixHeaders/App-Prefix.pch",
        "-MMD", "-MT", "dependencies", "-MF", "/DD/x.d",
        "-c", "/src/A.m", "-o", "/DD/x.o",
    ]

    // MARK: - ClangCommandEditing

    func testRespPathAndFileLevelFlags() {
        XCTAssertEqual(ClangCommandEditing.respPath(in: xcodeCommand),
                       "/DD/App.build/Objects-normal/arm64/7187679823f38a2a940e0043cdf9d637-common-args.resp")
        XCTAssertEqual(ClangCommandEditing.fileLevelFlags(in: xcodeCommand), ["-fno-objc-arc", "-Wno-unused"])
    }

    func testRemovingFileLevelFlagsKeepsEverythingElse() {
        let stripped = ClangCommandEditing.removingFileLevelFlags(xcodeCommand)
        XCTAssertFalse(stripped.contains("-fno-objc-arc"))
        XCTAssertFalse(stripped.contains("-Wno-unused"))
        XCTAssertEqual(stripped.count, xcodeCommand.count - 2)
        XCTAssertEqual(ClangCommandEditing.value(after: "-include", in: stripped), "/DD/PrefixHeaders/App-Prefix.pch")
    }

    func testNoRespMeansNoChange() {
        let tokens = ["clang", "-fno-objc-arc", "-c", "a.m"]
        XCTAssertNil(ClangCommandEditing.respPath(in: tokens))
        XCTAssertEqual(ClangCommandEditing.fileLevelFlags(in: tokens), [])
        XCTAssertEqual(ClangCommandEditing.removingFileLevelFlags(tokens), tokens)
    }

    func testValueAfterMissingFlag() {
        XCTAssertNil(ClangCommandEditing.value(after: "-o", in: ["clang", "-o"]))
        XCTAssertNil(ClangCommandEditing.value(after: "-x", in: ["clang"]))
    }

    // MARK: - PrecompiledHeader

    func testIncludedPCH() {
        let found = PrecompiledHeader.includedPCH(in: xcodeCommand)
        XCTAssertEqual(found?.path, "/DD/PrefixHeaders/App-Prefix.pch")
        XCTAssertEqual(found.map { xcodeCommand[$0.index] }, "/DD/PrefixHeaders/App-Prefix.pch")
        XCTAssertNil(PrecompiledHeader.includedPCH(in: ["clang", "-include", "Foo.h"]))
    }

    func testIncompatiblePCHFailureDetection() {
        XCTAssertTrue(PrecompiledHeader.isIncompatiblePCHFailure(
            "error: precompiled file '/x.pch.gch' was compiled with module cache path ''"))
        XCTAssertFalse(PrecompiledHeader.isIncompatiblePCHFailure("error: use of undeclared identifier 'foo'"))
        XCTAssertFalse(PrecompiledHeader.isIncompatiblePCHFailure("warning: PCH file is old"))
    }

    // MARK: - 构建清单

    func testParseCompileTasksFromManifest() throws {
        let key = "P1:target-App-abc-:Debug:CompileC /DD/Debug-iphonesimulator/App.build/Objects-normal/arm64/My File.o "
            + "/src/My File.m normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler"
        let task: [String: Any] = [
            "tool": "ccompiler",
            "inputs": ["/src/My File.m", "/DD/Debug-iphonesimulator/App.build/Objects-normal/arm64/x-common-args.resp",
                       "/src/App-Prefix.pch", "<ClangStatCache>"],
            "outputs": ["/DD/Debug-iphonesimulator/App.build/Objects-normal/arm64/My File.o"],
            "description": "a \"quoted\" {brace} value",
        ]
        let other: [String: Any] = ["tool": "shell", "inputs": [], "outputs": []]
        let commands = try JSONSerialization.data(withJSONObject: [key: task, "P0:other": other])
        var manifest = Data("{\"client\":{\"name\":\"basic\"},\"commands\":".utf8)
        manifest.append(commands)
        manifest.append(Data("}".utf8))
        let path = NSTemporaryDirectory() + "nocompile-manifest-\(UUID().uuidString).json"
        try manifest.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = BuildManifest.parseCompileTasks(manifestPath: path)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.tasks.count, 1)
        let parsed = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(parsed.source, "/src/My File.m")
        XCTAssertEqual(parsed.arch, "arm64")
        XCTAssertEqual(parsed.language, "objective-c")
        XCTAssertEqual(parsed.platform, "iphonesimulator")
        XCTAssertEqual(parsed.prefixHeader, "/src/App-Prefix.pch")
        XCTAssertTrue(parsed.resp?.hasSuffix("common-args.resp") ?? false)
    }

    func testTruncatedManifestIsIncomplete() throws {
        let path = NSTemporaryDirectory() + "nocompile-manifest-\(UUID().uuidString).json"
        try Data("{\"commands\":{\"P0:a\":{\"tool\":\"x\"},\"P1:b\":{\"to".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(BuildManifest.parseCompileTasks(manifestPath: path).complete)
    }

    func testIntermediatePathPlatform() {
        XCTAssertEqual(BuildManifest.configurationDirectory(ofIntermediatePath: "/DD/Debug-iphoneos/A.build/Objects-normal/arm64/x.o"), "Debug-iphoneos")
        XCTAssertEqual(BuildManifest.platform(ofIntermediatePath: "/DD/Debug-iphoneos/A.build/Objects-normal/arm64/x.o"), "iphoneos")
        XCTAssertEqual(BuildManifest.platform(ofIntermediatePath: "/DD/Debug-Staging/A.build/Objects-normal/arm64/x.o"), "macosx")
        XCTAssertEqual(BuildManifest.platform(ofIntermediatePath: "/DD/Debug-appletvos/A.build/Objects-normal/arm64/x.o"), "iphoneos")
        XCTAssertNil(BuildManifest.platform(ofIntermediatePath: "/no/build/dir/x.o"))
    }

    // MARK: - 签名身份 / 依赖文件 / 路径

    func testSigningIdentityFromPlainText() {
        let text = """
        export EXPANDED_CODE_SIGN_IDENTITY=1111
        /usr/bin/codesign --force --sign 0123456789ABCDEF --entitlements x /a.app
        /usr/bin/codesign --force --sign - /b.dylib
        """
        XCTAssertEqual(ProjectInfo.signingIdentity(fromPlainText: text), "0123456789ABCDEF")
        XCTAssertEqual(ProjectInfo.signingIdentity(fromPlainText: "export EXPANDED_CODE_SIGN_IDENTITY=2222"), "2222")
        XCTAssertNil(ProjectInfo.signingIdentity(fromPlainText: "nothing here"))
    }

    func testMakefileDependencies() {
        let text = "dependencies: /src/a.m \\\n  /src/My\\ Dir/b.h /Applications/Xcode.app/x.h \\\n  /src/c$$.h\n"
        XCTAssertEqual(HeaderDependencyIndex.dependencies(in: Data(text.utf8)), ["/src/a.m", "/src/My Dir/b.h", "/src/c$.h"])
        XCTAssertEqual(HeaderDependencyIndex.dependencies(in: Data("x.o: ".utf8)), [])
    }

    func testPathHelpers() {
        XCTAssertTrue(ProjectInfo.isPath("/a/b/c", inside: "/a/b"))
        XCTAssertTrue(ProjectInfo.isPath("/a/b", inside: "/a/b/"))
        XCTAssertFalse(ProjectInfo.isPath("/a/bc", inside: "/a/b"))
        XCTAssertEqual(ProjectInfo.absolute("../x", relativeTo: "/a/b"), "/a/x")
        XCTAssertEqual(ProjectInfo.absolute("/abs/./y", relativeTo: "/a/b"), "/abs/y")
    }

    func testShellQuoted() {
        XCTAssertEqual(Diagnostics.shellQuoted("-DFOO=1"), "-DFOO=1")
        XCTAssertEqual(Diagnostics.shellQuoted(""), "''")
        XCTAssertEqual(Diagnostics.shellQuoted("a b"), "'a b'")
        XCTAssertEqual(Diagnostics.shellQuoted("it's"), #"'it'\''s'"#)
    }

    func testDeviceConnectionCandidates() {
        let devices = [
            DeviceBridge.MuxDevice(id: 1, serial: "A", connectionType: "Network"),
            DeviceBridge.MuxDevice(id: 2, serial: "A", connectionType: "USB"),
            DeviceBridge.MuxDevice(id: 3, serial: "B", connectionType: "Network"),
        ]
        XCTAssertEqual(DeviceBridge.connectionCandidates(devices).map(\.id), [2, 3])
    }

    func testFileWatcherFilters() {
        XCTAssertTrue(FileWatcher.isWatched("/a/B.swift"))
        XCTAssertTrue(FileWatcher.isWatched("/a/Main.STORYBOARD"))
        XCTAssertTrue(FileWatcher.isWatched("/a/Podfile.lock"))
        XCTAssertFalse(FileWatcher.isWatched("/a/README.md"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/DerivedData/x.swift"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/.git/x.m"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/Foo~.m"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/Foo.m~"))
        // 设备后缀是合法的资源名
        XCTAssertFalse(FileWatcher.isIgnored("/a/icon@2x~ipad.png"))
        XCTAssertFalse(FileWatcher.isIgnored("/a/Main~iphone.xib"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/.hidden.swift"))
        XCTAssertTrue(FileWatcher.isIgnored("/a/Build/A.app/Info.plist"))
        XCTAssertFalse(FileWatcher.isIgnored("/a/com.apple.foo/x.swift"))
        XCTAssertFalse(FileWatcher.isIgnored("/a/Sources/x.swift"))
    }

    func testColorComponentFormats() {
        XCTAssertEqual(ResourceCompiler.colorComponent("0.500"), 0.5)
        XCTAssertEqual(ResourceCompiler.colorComponent("0xFF"), 1)
        XCTAssertEqual(ResourceCompiler.colorComponent("255"), 1)
        XCTAssertEqual(ResourceCompiler.colorComponent("1"), 1)
        XCTAssertEqual(ResourceCompiler.colorComponent("0"), 0)
        XCTAssertEqual(ResourceCompiler.colorComponent(NSNumber(value: 0.25)), 0.25)
        XCTAssertNil(ResourceCompiler.colorComponent("abc"))
    }

    func testEncodeSkipsInvalidJSON() throws {
        // 含 Date 的字典不是合法 JSON：编码时丢弃 json 部分而不是崩溃
        let frame = NCFrameCodec.encode(NCMessage(type: .config, json: ["date": Date()]))
        let decoded = try XCTUnwrap(NCFrameCodec.decode(from: frame))
        XCTAssertNil(decoded.message.json)
    }

    func testFirstErrorLocation() {
        let output = """
        /Users/me/My Proj/A.m:12:5: warning: unused variable
        /Users/me/My Proj/A.m:30:9: error: use of undeclared identifier 'x'
        /Users/me/B.m:3:1: error: another
        """
        let location = InjectionRecord.firstErrorLocation(in: output)
        XCTAssertEqual(location?.path, "/Users/me/My Proj/A.m")
        XCTAssertEqual(location?.line, 30)
        XCTAssertEqual(InjectionRecord.firstErrorLocation(in: "/a/b.h:7:2: fatal error: 'c.h' file not found")?.line, 7)
        XCTAssertNil(InjectionRecord.firstErrorLocation(in: "error: linker command failed"))

        var record = InjectionRecord(file: "A.m", clientName: "App", platformTitle: "模拟器", success: false,
                                     duration: 0, message: "编译失败", refreshed: [])
        record.path = "/src/A.m"
        XCTAssertEqual(record.sourceLocation?.path, "/src/A.m")
        XCTAssertNil(record.sourceLocation?.line)
    }
}
