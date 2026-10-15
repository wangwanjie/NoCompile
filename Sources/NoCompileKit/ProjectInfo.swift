//
//  ProjectInfo.swift
//  从构建日志 / DerivedData 提取签名身份，并把头文件变更映射到实现文件。
//

import Foundation

public enum ProjectInfo {

    /// 从构建日志明文中提取最近一次的代码签名身份（真机注入需要）
    public static func signingIdentity(fromPlainText text: String) -> String? {
        // 形如：/usr/bin/codesign --force --sign <40位SHA1 或 "身份名"> ...
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard line.contains("codesign"), line.contains("--sign") else {
                continue
            }
            let tokens = CommandTokenizer.tokenize(line)
            if let idx = tokens.firstIndex(of: "--sign"), idx + 1 < tokens.count {
                let identity = tokens[idx + 1]
                if identity != "-" {
                    return identity
                }
            }
        }
        // 退回环境变量形式
        for line in lines.reversed() {
            if let range = line.range(of: "EXPANDED_CODE_SIGN_IDENTITY=") {
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let identity = CommandTokenizer.tokenize(value).first ?? value
                if !identity.isEmpty, identity != "-" {
                    return identity
                }
            }
        }
        return nil
    }

    /// 头文件变更 → 依赖它的实现文件。扫描 Intermediates.noindex 下的 .d 文件。
    public static func implementationFiles(dependingOn header: String, derivedDataPath: String) -> [String] {
        let fm = FileManager.default
        let intermediates = "\(derivedDataPath)/Build/Intermediates.noindex"
        guard let enumerator = fm.enumerator(atPath: intermediates) else {
            return []
        }
        var result = Set<String>()
        for case let path as String in enumerator {
            guard path.hasSuffix(".d") else {
                continue
            }
            let full = "\(intermediates)/\(path)"
            guard let content = try? String(contentsOfFile: full, encoding: .utf8),
                  content.contains(header) else {
                continue
            }
            // .d 文件的 target 即对应实现文件：取其同名 .m/.mm/.c/.cpp
            // Makefile 依赖格式：第一个 token（去掉结尾冒号）是产物，其余是依赖
            for token in content.components(separatedBy: .whitespacesAndNewlines) {
                let clean = token.replacingOccurrences(of: "\\", with: "")
                if clean.hasSuffix(".m") || clean.hasSuffix(".mm") || clean.hasSuffix(".c")
                    || clean.hasSuffix(".cpp") || clean.hasSuffix(".cc") {
                    if fm.fileExists(atPath: clean) {
                        result.insert(clean)
                    }
                }
            }
        }
        return Array(result)
    }

    /// 为平台名解析 SDK 路径
    public static func sdkPath(for platformName: String) -> String? {
        let result = Shell.run("/usr/bin/xcrun", ["--sdk", platformName, "--show-sdk-path"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
