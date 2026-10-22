//
//  CommandTokenizerTests.swift
//  构建日志命令行切分：Xcode 的反斜杠转义与引号包裹
//

import XCTest
@testable import NoCompileKit

final class CommandTokenizerTests: XCTestCase {

    func testSplitsOnSpacesAndTabs() {
        XCTAssertEqual(CommandTokenizer.tokenize("clang  -c\ta.m   -o a.o"), ["clang", "-c", "a.m", "-o", "a.o"])
    }

    func testEmptyAndBlankLines() {
        XCTAssertEqual(CommandTokenizer.tokenize(""), [])
        XCTAssertEqual(CommandTokenizer.tokenize("   \t "), [])
    }

    func testBackslashEscapedSpaceStaysInToken() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"clang -c /Users/me/My\ Project/a.m"#),
                       ["clang", "-c", "/Users/me/My Project/a.m"])
    }

    func testBackslashEscapedEquals() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"-DFOO\=1"#), ["-DFOO=1"])
    }

    func testDoubleAndSingleQuotes() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"codesign --sign "Apple Development: Me (ABC)" x"#),
                       ["codesign", "--sign", "Apple Development: Me (ABC)", "x"])
        XCTAssertEqual(CommandTokenizer.tokenize("a 'b c' d"), ["a", "b c", "d"])
    }

    func testOtherQuoteInsideQuotesIsLiteral() {
        XCTAssertEqual(CommandTokenizer.tokenize(#""it's" 'say "hi"'"#), ["it's", #"say "hi""#])
    }

    func testEmptyQuotedStringIsAToken() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"a "" b"#), ["a", "", "b"])
    }

    func testEscapeInsideQuotes() {
        XCTAssertEqual(CommandTokenizer.tokenize(#""a\"b""#), [#"a"b"#])
    }

    func testSingleQuotesAreLiteral() {
        // swiftc -### 的输出用单引号包裹参数，里面的反斜杠必须原样保留
        XCTAssertEqual(CommandTokenizer.tokenize(#"-Xcc '-DM=a\b' 'a b.swift'"#), ["-Xcc", #"-DM=a\b"#, "a b.swift"])
        // shell 风格的单引号转义：'it'\''s'
        XCTAssertEqual(CommandTokenizer.tokenize(#"'it'\''s'"#), ["it's"])
    }

    func testBackslashInDoubleQuotesOnlyEscapesSpecialCharacters() {
        XCTAssertEqual(CommandTokenizer.tokenize(#""C:\dir\n""#), [#"C:\dir\n"#])
        XCTAssertEqual(CommandTokenizer.tokenize(#""a\\b\$c""#), [#"a\b$c"#])
    }

    func testTrailingBackslashIsDropped() {
        XCTAssertEqual(CommandTokenizer.tokenize("a b\\"), ["a", "b"])
    }

    func testUnicodePath() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"clang -c /Users/me/中文\ 目录/文件.m"#),
                       ["clang", "-c", "/Users/me/中文 目录/文件.m"])
    }

    func testAdjacentQuotedAndBareParts() {
        XCTAssertEqual(CommandTokenizer.tokenize(#"-I"/a b"/c"#), ["-I/a b/c"])
    }
}
