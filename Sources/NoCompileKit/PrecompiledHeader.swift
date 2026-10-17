//
//  PrecompiledHeader.swift
//  自建预编译头（PCH）。
//
//  Xcode 16+ 的显式模块构建会用自己的参数预编译 PCH（模块缓存路径为空、依赖显式 .pcm），
//  而日志里记录的单文件编译命令不含这些参数。直接复用 Xcode 产出的 .pch.gch 时，
//  clang 报 "precompiled file ... was compiled with module cache path ''" 之类的错误。
//  这时改为用本文件的命令参数从前缀头文件源码自己预编译一份，放进 NoCompile 的缓存目录复用；
//  前缀头文件及其依赖变化后自动重建。
//

import Foundation

enum PrecompiledHeader {

    /// 命令里 `-include <x>.pch` 对应的 PCH 路径（只处理预编译形式；直接 include 的 .h 不需要处理）
    static func includedPCH(in tokens: [String]) -> (index: Int, path: String)? {
        var i = 0
        while i + 1 < tokens.count {
            if tokens[i] == "-include", tokens[i + 1].hasSuffix(".pch") {
                return (i + 1, tokens[i + 1])
            }
            i += 1
        }
        return nil
    }

    /// 输出是否表明失败来自 Xcode 产出的 PCH 与当前命令不兼容
    static func isIncompatiblePCHFailure(_ output: String) -> Bool {
        let markers = [
            "precompiled file", "PCH file", "was compiled with module cache path",
            "malformed or corrupted AST file", "module file ", "-include-pch",
        ]
        return output.contains("error:") && markers.contains(where: { output.contains($0) })
    }

    /// 找到 Xcode 预编译这份 PCH 时用的前缀头文件源码：
    /// 同目录的 `<x>.pch.d` 依赖文件里，排除系统路径与 DerivedData 产物，取与 PCH 同名（或第一个 .pch/.h）的文件
    static func sourceHeader(forPCH pchPath: String) -> String? {
        let depFile = pchPath + ".d"
        guard let data = FileManager.default.contents(atPath: depFile) else {
            return nil
        }
        let deps = HeaderDependencyIndex.dependencies(in: data).filter {
            !$0.hasPrefix("/Applications/") && !$0.hasPrefix("/Library/Developer/") && !$0.contains("/DerivedData/")
        }
        let name = (pchPath as NSString).lastPathComponent
        if let exact = deps.first(where: { ($0 as NSString).lastPathComponent == name }) {
            return exact
        }
        return deps.first { $0.hasSuffix(".pch") } ?? deps.first { $0.hasSuffix(".h") }
    }

    /// 取得（必要时构建）自建 PCH，返回 .pch 文件路径
    /// - Parameters:
    ///   - tokens: 已清洗的单文件编译命令（含 -c / -o / -include）
    ///   - pchPath: 命令里 -include 的 .pch 路径
    static func ownPCH(tokens: [String], pchPath: String, workingDirectory: String,
                       forceRebuild: Bool = false) -> (path: String?, error: String?) {
        guard let header = sourceHeader(forPCH: pchPath) else {
            return (nil, "找不到 \((pchPath as NSString).lastPathComponent) 的前缀头文件源码（\(pchPath).d 缺失）")
        }
        let language: String
        switch BuildLog.valueForFlag("-x", in: tokens) ?? "objective-c" {
        case "c":
            language = "c-header"
        case "c++":
            language = "c++-header"
        case "objective-c++":
            language = "objective-c++-header"
        default:
            language = "objective-c-header"
        }

        // PCH 编译参数：沿用单文件命令，去掉 -c / -o / -include / -x，改成编译头文件
        var args: [String] = []
        var i = 1
        var identity = [header, language]
        while i < tokens.count {
            let token = tokens[i]
            if (token == "-c" || token == "-o" || token == "-x"), i + 1 < tokens.count {
                i += 2
                continue
            }
            if token == "-include", i + 1 < tokens.count, tokens[i + 1] == pchPath {
                i += 2
                continue
            }
            args.append(token)
            identity.append(token)
            // 响应文件里的参数同样决定 PCH 内容，计入缓存键
            if token.hasPrefix("@"), let content = try? String(contentsOfFile: String(token.dropFirst()), encoding: .utf8) {
                identity.append(content)
            }
            i += 1
        }

        let directory = NSHomeDirectory() + "/Library/Caches/NoCompile/PCH"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stem = "\(((header as NSString).lastPathComponent as NSString).deletingPathExtension)-\(stableHash(identity.joined(separator: "\u{1}")))"
        let output = "\(directory)/\(stem).pch"
        let depPath = "\(directory)/\(stem).d"

        if !forceRebuild, isFresh(output: output, depFile: depPath) {
            return (output, nil)
        }
        let command = args + ["-x", language, header, "-o", output, "-MD", "-MF", depPath]
        let started = Date()
        let result = Shell.run(tokens[0], command, workingDirectory: workingDirectory)
        guard result.succeeded, FileManager.default.fileExists(atPath: output) else {
            try? FileManager.default.removeItem(atPath: output)
            let message = (result.stderr + result.stdout).components(separatedBy: "\n")
                .filter { $0.contains("error:") }.prefix(5).joined(separator: "\n")
            Diagnostics.shared.failure(stage: "自建PCH", file: header, summary: message.isEmpty ? "预编译失败" : message,
                                       command: [tokens[0]] + command, workingDirectory: workingDirectory,
                                       output: result.stdout + result.stderr)
            return (nil, "自建预编译头失败：\(message)")
        }
        Diagnostics.shared.log("自建PCH", "\((header as NSString).lastPathComponent) → \(output)，用时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return (output, nil)
    }

    /// 依赖里任何一个文件比 PCH 新（或依赖文件缺失）就算过期
    private static func isFresh(output: String, depFile: String) -> Bool {
        let fm = FileManager.default
        guard let built = (try? fm.attributesOfItem(atPath: output))?[.modificationDate] as? Date,
              let data = fm.contents(atPath: depFile) else {
            return false
        }
        for dep in HeaderDependencyIndex.dependencies(in: data) {
            if let date = (try? fm.attributesOfItem(atPath: dep))?[.modificationDate] as? Date, date > built {
                return false
            }
        }
        return true
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
