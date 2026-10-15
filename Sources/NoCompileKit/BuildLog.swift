//
//  BuildLog.swift
//  定位 DerivedData 与构建日志，从 .xcactivitylog 中提取编译命令。
//
//  做法：gunzip 解压最新日志（SLF 二进制中夹带明文命令），按 \r 切行，
//  抓取 Swift 模块的 driver 命令（builtin-SwiftDriver -- swiftc ...）
//  与 ObjC/C 的 clang 单文件命令（... -c <源文件> ...）。
//

import Foundation

/// 一条从日志中解析出的编译命令
public struct RawCompileCommand {
    public enum Kind {
        case swiftModule    // 整个模块的 swiftc driver 命令
        case clangFile      // 单个 .m/.mm/.c/.cpp 的 clang 命令
    }
    public let kind: Kind
    public let tokens: [String]       // 已切分的参数数组
    public let workingDirectory: String
    public let moduleName: String?    // Swift 模块名
    public let sdkPath: String?
}

public struct BuildLog {

    public let derivedDataPath: String
    public let logsDirectory: String

    /// 根据工程路径定位 DerivedData 与构建日志目录
    public static func locate(projectPath: String, customDerivedData: String? = nil) -> BuildLog? {
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: projectPath)
        let projectName = projectURL.deletingPathExtension().lastPathComponent

        var candidates: [String] = []
        if let customDerivedData, !customDerivedData.isEmpty {
            candidates.append(customDerivedData)
        }
        // 工程内相对路径（部分团队把 DerivedData 放工程里）
        candidates.append(projectURL.deletingLastPathComponent().appendingPathComponent("DerivedData").path)
        // 默认全局位置
        let home = NSHomeDirectory()
        candidates.append("\(home)/Library/Developer/Xcode/DerivedData")

        for base in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: base, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // 自定义 / 相对 DerivedData 直接就是工程的 DerivedData 根
            if base.hasSuffix("/DerivedData") == false || base == customDerivedData {
                if let log = buildLog(forProjectName: projectName, inDerivedDataRoot: base, exactRoot: true) {
                    return log
                }
            }
            if let log = buildLog(forProjectName: projectName, inDerivedDataRoot: base, exactRoot: false) {
                return log
            }
        }
        return nil
    }

    private static func buildLog(forProjectName name: String, inDerivedDataRoot root: String, exactRoot: Bool) -> BuildLog? {
        let fm = FileManager.default
        func logsDir(in dataPath: String) -> String? {
            let dir = "\(dataPath)/Logs/Build"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            return nil
        }
        if exactRoot {
            if let dir = logsDir(in: root) {
                return BuildLog(derivedDataPath: root, logsDirectory: dir)
            }
            return nil
        }
        // 在 DerivedData 根下找以 "<工程名>-" 开头、修改时间最新的目录
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else {
            return nil
        }
        let prefix = "\(name)-"
        let matched = entries.filter { $0.hasPrefix(prefix) }
            .map { "\(root)/\($0)" }
            .filter { logsDir(in: $0) != nil }
            .sorted { lhs, rhs in
                let l = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? nil
                let r = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? nil
                return (l ?? .distantPast) > (r ?? .distantPast)
            }
        if let best = matched.first, let dir = logsDir(in: best) {
            return BuildLog(derivedDataPath: best, logsDirectory: dir)
        }
        return nil
    }

    /// 解压并合并所有日志的明文，按修改时间从新到旧
    public func extractPlainText() -> String {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: logsDirectory) else {
            return ""
        }
        let logs = entries.filter { $0.hasSuffix(".xcactivitylog") }
            .map { "\(logsDirectory)/\($0)" }
            .sorted { lhs, rhs in
                let l = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? nil
                let r = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? nil
                return (l ?? .distantPast) > (r ?? .distantPast)
            }
        var merged = ""
        for log in logs {
            let result = Shell.run("/usr/bin/gunzip", ["-c", log])
            if result.succeeded {
                merged += result.stdout.replacingOccurrences(of: "\r", with: "\n")
                merged += "\n"
            }
        }
        return merged
    }

    /// 解析日志，返回：swift 模块命令（按模块名）与 clang 单文件命令（按源文件绝对路径）
    public func parse() -> (swiftModules: [RawCompileCommand], clangFiles: [String: RawCompileCommand]) {
        let text = extractPlainText()
        let lines = text.components(separatedBy: "\n")

        var swiftModules: [RawCompileCommand] = []
        var seenModules = Set<String>()
        var clangFiles: [String: RawCompileCommand] = [:]
        var currentWorkingDir = NSHomeDirectory()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cd ") {
                let dir = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if dir.hasPrefix("/") {
                    currentWorkingDir = dir
                }
                continue
            }
            // Swift 模块 driver 命令
            if let range = line.range(of: "builtin-SwiftDriver -- ") {
                let command = String(line[range.upperBound...])
                let tokens = CommandTokenizer.tokenize(command)
                guard tokens.count > 1 else { continue }
                let moduleName = valueForFlag("-module-name", in: tokens)
                if let moduleName, seenModules.contains(moduleName) {
                    continue   // 每个模块只保留第一条（最新日志在前）
                }
                if let moduleName { seenModules.insert(moduleName) }
                swiftModules.append(RawCompileCommand(
                    kind: .swiftModule, tokens: tokens, workingDirectory: currentWorkingDir,
                    moduleName: moduleName, sdkPath: valueForFlag("-sdk", in: tokens)))
                continue
            }
            // clang 单文件命令：行首必须就是 clang 可执行文件，排除 builtin-ScanDependencies 等包装行
            if line.contains(" -c ") {
                let tokens = CommandTokenizer.tokenize(line)
                guard let executable = tokens.first,
                      executable.hasSuffix("/clang") || executable == "clang" else {
                    continue
                }
                guard let source = clangPrimarySource(in: line) else {
                    continue
                }
                if clangFiles[source] == nil {
                    clangFiles[source] = RawCompileCommand(
                        kind: .clangFile, tokens: tokens, workingDirectory: currentWorkingDir,
                        moduleName: nil, sdkPath: valueForFlag("-isysroot", in: tokens))
                }
            }
        }
        return (swiftModules, clangFiles)
    }

    /// 从 clang 命令里取 `-c` 后的源文件（仅限用户源码扩展名）
    private func clangPrimarySource(in line: String) -> String? {
        let tokens = CommandTokenizer.tokenize(line)
        guard let idx = tokens.firstIndex(of: "-c"), idx + 1 < tokens.count else {
            return nil
        }
        let source = tokens[idx + 1]
        let exts = [".m", ".mm", ".c", ".cpp", ".cc", ".cxx"]
        if exts.contains(where: { source.hasSuffix($0) }) {
            return source
        }
        return nil
    }

    private func valueForFlag(_ flag: String, in tokens: [String]) -> String? {
        guard let idx = tokens.firstIndex(of: flag), idx + 1 < tokens.count else {
            return nil
        }
        return tokens[idx + 1]
    }
}
