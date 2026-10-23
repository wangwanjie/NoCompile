//
//  ShellScriptLintTests.swift
//  Xcode 用 /bin/bash 3.2 执行 Run Script。UTF-8 环境下 bash 3.2 会把紧跟在 $VAR 后面的非 ASCII 字符
//  （如全角的「（」「，」）当成变量名的一部分，配合 set -u 直接报 unbound variable 退出，导致接入方工程编译失败。
//  这类变量必须写成 ${VAR}，这里扫描仓库里的脚本拦住
//

import XCTest

final class ShellScriptLintTests: XCTestCase {

    /// 仓库根目录（本文件位于 Tests/NoCompileKitTests/）
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testVariablesBeforeNonASCIIAreBraced() throws {
        var files = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("Scripts").path)
            .filter { $0.hasSuffix(".sh") }
            .map { "Scripts/" + $0 }
        // App 工程的 Run Script 写在 project.yml 里
        files.append("App/project.yml")
        XCTAssertTrue(files.contains("Scripts/nocompile_copy_bundle.sh"))

        let regex = try NSRegularExpression(pattern: "\\$[A-Za-z_][A-Za-z0-9_]*[^\\x00-\\x7F]")
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "以下变量紧跟非 ASCII 字符，请写成 ${VAR}：\n" + offenders.joined(separator: "\n"))
    }
}
