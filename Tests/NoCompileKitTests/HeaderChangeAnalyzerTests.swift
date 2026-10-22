//
//  HeaderChangeAnalyzerTests.swift
//  头文件改动分析：差异标识符、外层声明、声明提取与依赖筛选
//

import XCTest
@testable import NoCompileKit

final class HeaderChangeAnalyzerTests: XCTestCase {

    func testChangedIdentifiersFromSnapshotDiff() throws {
        let analyzer = HeaderChangeAnalyzer()
        let header = "/NoCompileTests/h/Foo.h"
        analyzer.update(header, text: "#define kTimeout 10\nvoid keepMe(void);\n")
        let changed = try XCTUnwrap(analyzer.changedIdentifiers(header: header,
                                                                newText: "#define kTimeout 20\nvoid keepMe(void);\n",
                                                                extraOldTexts: []))
        XCTAssertTrue(changed.contains("kTimeout"))
        XCTAssertFalse(changed.contains("keepMe"), "未改动的行不应计入")
        XCTAssertFalse(changed.contains("define"), "语法关键字被过滤")
    }

    func testChangeInsideBodyIncludesEnclosingDeclaration() throws {
        let analyzer = HeaderChangeAnalyzer()
        let header = "/NoCompileTests/h/Inline.h"
        let old = "static inline int compute(int x) {\n    return x + 1;\n}\n"
        let new = "static inline int compute(int x) {\n    return x + 2;\n}\n"
        analyzer.update(header, text: old)
        let changed = try XCTUnwrap(analyzer.changedIdentifiers(header: header, newText: new, extraOldTexts: []))
        XCTAssertTrue(changed.contains("compute"))
    }

    func testIdenticalContentReturnsNil() {
        let analyzer = HeaderChangeAnalyzer()
        let header = "/NoCompileTests/h/Same.h"
        analyzer.update(header, text: "int a;")
        XCTAssertNil(analyzer.changedIdentifiers(header: header, newText: "int a;", extraOldTexts: []))
    }

    func testExtraOldTextUsedWhenNoSnapshot() throws {
        let analyzer = HeaderChangeAnalyzer()
        let changed = try XCTUnwrap(analyzer.changedIdentifiers(header: "/NoCompileTests/h/Copy.h",
                                                                newText: "extern int newValue;",
                                                                extraOldTexts: ["extern int oldValue;"]))
        XCTAssertTrue(changed.contains("newValue"))
        XCTAssertTrue(changed.contains("oldValue"))
    }

    func testBraceBalance() {
        XCTAssertEqual(HeaderChangeAnalyzer.braceBalance(of: "void f() {"), 1)
        XCTAssertEqual(HeaderChangeAnalyzer.braceBalance(of: "}"), -1)
        XCTAssertEqual(HeaderChangeAnalyzer.braceBalance(of: #"printf("{");"#), 0)
        XCTAssertEqual(HeaderChangeAnalyzer.braceBalance(of: "int x; // {"), 0)
    }

    func testEnclosingOpenerLines() {
        let lines = ["struct Outer {", "  struct Inner {", "    int a;", "  };", "  int b;", "};"]
        XCTAssertEqual(HeaderChangeAnalyzer.enclosingOpenerLines(of: 2, in: lines), [1, 0])
        XCTAssertEqual(HeaderChangeAnalyzer.enclosingOpenerLines(of: 4, in: lines), [0])
        XCTAssertEqual(HeaderChangeAnalyzer.enclosingOpenerLines(of: 0, in: lines), [0])
        XCTAssertEqual(HeaderChangeAnalyzer.enclosingOpenerLines(of: 99, in: lines), [])
    }

    func testDeclaredIdentifiers() {
        let text = """
        #define MAX_COUNT 3
        typedef NS_ENUM(NSInteger, PlayState) {
            PlayStateIdle,
            PlayStatePlaying = 2,
        };
        @interface PlayerView : UIView
        - (void)play;
        @end
        @protocol PlayerDelegate
        @end
        FOUNDATION_EXPORT NSString *const PlayerErrorDomain;
        void PlayerReset(void);
        """
        let ids = HeaderChangeAnalyzer.declaredIdentifiers(in: text)
        for expected in ["MAX_COUNT", "PlayState", "PlayStateIdle", "PlayStatePlaying", "PlayerView", "PlayerDelegate",
                         "PlayerErrorDomain", "PlayerReset"] {
            XCTAssertTrue(ids.contains(expected), "应包含 \(expected)")
        }
        XCTAssertFalse(ids.contains("NS_ENUM"))
    }

    func testSimilarity() {
        XCTAssertEqual(HeaderChangeAnalyzer.similarity("a\nb", "a\nb"), 1)
        XCTAssertEqual(HeaderChangeAnalyzer.similarity("a\nb", "a\nc"), 0.5)
        XCTAssertEqual(HeaderChangeAnalyzer.similarity("", ""), 1)
    }

    func testFilterSourcesMentioningIdentifiers() throws {
        let dir = NSTemporaryDirectory() + "nocompile-filter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let uses = dir + "/Uses.m"
        let other = dir + "/Other.m"
        try "int v = kTimeout;".write(toFile: uses, atomically: true, encoding: .utf8)
        try "int v = kTimeoutLong;".write(toFile: other, atomically: true, encoding: .utf8)
        XCTAssertEqual(HeaderChangeAnalyzer.filter(sources: [uses, other], mentioning: ["kTimeout"]), [uses], "按完整单词匹配")
        XCTAssertEqual(HeaderChangeAnalyzer.filter(sources: [uses], mentioning: []), [])
        // 读不到的文件保守地保留
        XCTAssertEqual(HeaderChangeAnalyzer.filter(sources: [dir + "/missing.m"], mentioning: ["x"]), [dir + "/missing.m"])
    }
}
