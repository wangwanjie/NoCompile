//
//  BuildLog.swift
//  定位 DerivedData 与构建日志，从 .xcactivitylog 中提取编译命令。
//
//  做法：gunzip 解压日志（SLF 二进制中夹带明文命令），按 \r 切行，
//  抓取 Swift 模块的 driver 命令（builtin-SwiftDriver -- swiftc ...）
//  与 ObjC/C/C++ 的 clang 单文件命令（... -c <源文件> ...）。
//  同一模块 / 文件可能同时存在模拟器、真机、macOS 三套命令，按平台分别保存。
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
    public let platform: String       // iphonesimulator / iphoneos / macosx
    public let target: String?        // -target 三元组，链接时沿用

    /// 由 -target 三元组推断平台名
    public static func platform(forTarget target: String?) -> String {
        guard let target else {
            return "unknown"
        }
        if target.hasSuffix("-simulator") {
            return "iphonesimulator"
        }
        if target.contains("-macabi") {
            return "maccatalyst"
        }
        if target.contains("-ios") {
            return "iphoneos"
        }
        if target.contains("-macos") {
            return "macosx"
        }
        return "unknown"
    }
}

/// 解析结果：按平台索引的编译命令
public struct ParsedCommands {
    /// Swift 模块命令（同一模块在不同平台各一条）
    public var swiftModules: [RawCompileCommand] = []
    /// clang 单文件命令，键为 "平台|源文件绝对路径"
    public var clangFiles: [String: RawCompileCommand] = [:]

    public static func clangKey(platform: String, source: String) -> String {
        return "\(platform)|\(canonicalPath(source))"
    }

    /// 解析符号链接后的路径。文件监听给出的是真实路径（如 /private/tmp/...），
    /// 构建日志里可能是带符号链接的写法（如 /tmp/...），比较前需统一
    public static func canonicalPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    public func swiftModules(for platform: String) -> [RawCompileCommand] {
        return swiftModules.filter { $0.platform == platform }
    }

    public func clangCommand(for source: String, platform: String) -> RawCompileCommand? {
        return clangFiles[Self.clangKey(platform: platform, source: source)]
    }

    public var clangFileCount: Int {
        return Set(clangFiles.keys.map { $0.components(separatedBy: "|").last ?? $0 }).count
    }
}

public struct BuildLog {

    public let derivedDataPath: String
    public let logsDirectory: String

    /// 根据工程路径定位 DerivedData 与构建日志目录
    public static func locate(projectPath: String, customDerivedData: String? = nil) -> BuildLog? {
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: projectPath)
        let projectName = projectURL.deletingPathExtension().lastPathComponent

        // 1. 显式指定的 DerivedData：既可能是工程自己的目录，也可能是全局根目录
        if let customDerivedData, !customDerivedData.isEmpty {
            if let log = buildLog(forProjectName: projectName, inDerivedDataRoot: customDerivedData, exactRoot: true) {
                return log
            }
            if let log = buildLog(forProjectName: projectName, inDerivedDataRoot: customDerivedData, exactRoot: false) {
                return log
            }
        }

        // 2. Xcode 偏好里设置的自定义 DerivedData 位置
        var roots: [String] = []
        if let xcodeCustom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           !xcodeCustom.isEmpty {
            roots.append((xcodeCustom as NSString).expandingTildeInPath)
        }
        // 3. 工程旁的 DerivedData 与全局默认位置
        roots.append(projectURL.deletingLastPathComponent().appendingPathComponent("DerivedData").path)
        roots.append("\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData")

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let log = buildLog(forProjectName: projectName, inDerivedDataRoot: root, exactRoot: false) {
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
        let prefix = "\(name.replacingOccurrences(of: " ", with: "_"))-"
        let matched = entries.filter { $0.hasPrefix(prefix) }
            .map { "\(root)/\($0)" }
            .filter { logsDir(in: $0) != nil }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        if let best = matched.first, let dir = logsDir(in: best) {
            return BuildLog(derivedDataPath: best, logsDirectory: dir)
        }
        return nil
    }

    static func modificationDate(of path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    /// 所有日志文件，按修改时间从新到旧
    public func logFiles() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory) else {
            return []
        }
        return entries.filter { $0.hasSuffix(".xcactivitylog") }
            .map { "\(logsDirectory)/\($0)" }
            .sorted { Self.modificationDate(of: $0) > Self.modificationDate(of: $1) }
    }

    /// 最新日志的修改时间，用于判断是否需要重新解析
    public func latestLogDate() -> Date {
        return logFiles().first.map { Self.modificationDate(of: $0) } ?? .distantPast
    }

    /// 解压并合并所有日志的明文，按修改时间从新到旧
    public func extractPlainText() -> String {
        var merged = ""
        for log in logFiles() {
            let result = Shell.run("/usr/bin/gunzip", ["-c", log])
            if result.succeeded {
                merged += result.stdout.replacingOccurrences(of: "\r", with: "\n")
                merged += "\n"
            }
        }
        return merged
    }

    /// 解析日志明文。新日志在前，同一 (模块, 平台) / (文件, 平台) 只保留最新一条
    public static func parse(plainText text: String) -> ParsedCommands {
        let lines = text.components(separatedBy: "\n")
        var parsed = ParsedCommands()
        var seenModules = Set<String>()
        var currentWorkingDir = NSHomeDirectory()

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cd ") {
                let dir = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if dir.hasPrefix("/") {
                    currentWorkingDir = CommandTokenizer.tokenize(dir).first ?? dir
                }
                continue
            }
            // Swift 模块 driver 命令
            if let range = line.range(of: "builtin-SwiftDriver -- ") {
                let tokens = CommandTokenizer.tokenize(String(line[range.upperBound...]))
                guard tokens.count > 1 else {
                    continue
                }
                let moduleName = valueForFlag("-module-name", in: tokens)
                let target = valueForFlag("-target", in: tokens)
                let platform = RawCompileCommand.platform(forTarget: target)
                let key = "\(moduleName ?? "?")|\(platform)"
                if seenModules.contains(key) {
                    continue
                }
                seenModules.insert(key)
                parsed.swiftModules.append(RawCompileCommand(
                    kind: .swiftModule, tokens: tokens, workingDirectory: currentWorkingDir,
                    moduleName: moduleName, platform: platform, target: target))
                continue
            }
            // clang 单文件命令：行首必须就是 clang 可执行文件，排除 builtin-ScanDependencies 等包装行
            if line.contains(" -c ") {
                let tokens = CommandTokenizer.tokenize(line)
                guard let executable = tokens.first,
                      executable.hasSuffix("/clang") || executable.hasSuffix("/clang++") || executable == "clang" else {
                    continue
                }
                guard let source = clangPrimarySource(in: tokens) else {
                    continue
                }
                let target = valueForFlag("-target", in: tokens)
                let platform = RawCompileCommand.platform(forTarget: target)
                let key = ParsedCommands.clangKey(platform: platform, source: source)
                if parsed.clangFiles[key] == nil {
                    parsed.clangFiles[key] = RawCompileCommand(
                        kind: .clangFile, tokens: tokens, workingDirectory: currentWorkingDir,
                        moduleName: nil, platform: platform, target: target)
                }
            }
        }
        return parsed
    }

    /// 便捷方法：解压并解析
    public func parse() -> ParsedCommands {
        return Self.parse(plainText: extractPlainText())
    }

    /// 从 clang 命令里取 `-c` 后的源文件（仅限用户源码扩展名）
    private static func clangPrimarySource(in tokens: [String]) -> String? {
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

    static func valueForFlag(_ flag: String, in tokens: [String]) -> String? {
        guard let idx = tokens.firstIndex(of: flag), idx + 1 < tokens.count else {
            return nil
        }
        return tokens[idx + 1]
    }
}
