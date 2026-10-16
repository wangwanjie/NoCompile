//
//  BuildLog.swift
//  定位 DerivedData 与构建日志，从 .xcactivitylog 中提取编译命令。
//
//  做法：gunzip 解压日志（SLF 二进制中夹带明文命令），按 \r 切行，
//  抓取 Swift 模块的 driver 命令（builtin-SwiftDriver -- swiftc ...）
//  与 ObjC/C/C++ 的 clang 单文件命令（... -c <源文件> ...）。
//  同一模块 / 文件可能同时存在模拟器、真机、macOS 三套命令，按平台分别保存；
//  同一平台多架构构建（如模拟器同时编 arm64 与 x86_64）时，每个架构的命令都保留。
//

import Foundation

/// 一条从日志中解析出的编译命令
public struct RawCompileCommand {
    public enum Kind {
        case swiftModule    // 整个模块的 swiftc driver 命令
        case clangFile      // 单个 .m/.mm/.c/.cpp 的 clang 命令
        case ibtool         // 单个 .storyboard/.xib 的 ibtool 编译命令
    }
    public let kind: Kind
    public let tokens: [String]       // 已切分的参数数组
    public let workingDirectory: String
    public let moduleName: String?    // Swift 模块名
    public let platform: String       // iphonesimulator / iphoneos / macosx
    public let target: String?        // -target 三元组，链接时沿用

    /// -target 三元组里的架构，例如 arm64-apple-ios15.0-simulator → arm64
    public var arch: String? {
        return Self.arch(forTarget: target)
    }

    /// 由 -target 三元组取架构（三元组第一段）
    public static func arch(forTarget target: String?) -> String? {
        guard let target, let first = target.split(separator: "-").first, !first.isEmpty else {
            return nil
        }
        return String(first)
    }

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
    /// Swift 模块命令（同一模块在不同平台、不同架构各一条，新日志在前）
    public var swiftModules: [RawCompileCommand] = []
    /// clang 单文件命令，键为 "平台|源文件绝对路径"，值为各架构的命令（新日志在前，每个架构一条）
    public var clangFiles: [String: [RawCompileCommand]] = [:]

    /// ibtool 命令，键为界面文件的规范化路径。nib 格式与模拟器 / 真机无关，不区分平台
    public var ibtoolCommands: [String: RawCompileCommand] = [:]

    public static func clangKey(platform: String, source: String) -> String {
        return "\(platform)|\(canonicalPath(source))"
    }

    /// 解析符号链接后的路径。文件监听给出的是真实路径（如 /private/tmp/...），
    /// 构建日志里可能是带符号链接的写法（如 /tmp/...），比较前需统一
    public static func canonicalPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// 某平台的 Swift 模块命令，每个模块只返回一条：
    /// 优先 -target 架构与 arch 一致的命令，没有则退回该模块最新的一条
    public func swiftModules(for platform: String, arch: String? = nil) -> [RawCompileCommand] {
        let candidates = swiftModules.filter { $0.platform == platform }
        var result: [RawCompileCommand] = []
        var indexByModule: [String: Int] = [:]
        for command in candidates {
            let moduleKey = command.moduleName ?? "?"
            guard let index = indexByModule[moduleKey] else {
                indexByModule[moduleKey] = result.count
                result.append(command)
                continue
            }
            // 已有的命令架构不匹配、当前命令匹配时替换
            if let arch, result[index].arch != arch, command.arch == arch {
                result[index] = command
            }
        }
        return result
    }

    /// 某平台某文件的 clang 命令：优先架构匹配的，没有则退回最新的一条
    public func clangCommand(for source: String, platform: String, arch: String? = nil) -> RawCompileCommand? {
        guard let commands = clangFiles[Self.clangKey(platform: platform, source: source)] else {
            return nil
        }
        if let arch, let matched = commands.first(where: { $0.arch == arch }) {
            return matched
        }
        return commands.first
    }

    /// 所有 clang 命令（含各架构）
    public var allClangCommands: [RawCompileCommand] {
        return clangFiles.values.flatMap { $0 }
    }

    public var clangFileCount: Int {
        return Set(clangFiles.keys.map { $0.components(separatedBy: "|").last ?? $0 }).count
    }

    public func ibtoolCommand(for source: String) -> RawCompileCommand? {
        return ibtoolCommands[Self.canonicalPath(source)]
    }

    /// 新增文件（构建日志里还没有它的命令）借用的 clang 命令模板：
    /// 同平台、同语言、与新文件目录最接近的已有文件。语言不同时退而求其次，由调用方改写 -x
    /// 多架构构建时优先取与 arch 一致的命令
    public func clangTemplate(for source: String, platform: String,
                              arch: String? = nil) -> (source: String, command: RawCompileCommand)? {
        let target = Self.canonicalPath(source)
        let language = Self.clangLanguage(forPath: target)
        var best: (source: String, command: RawCompileCommand, score: Int)? = nil
        for key in clangFiles.keys {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == platform, parts[1] != target,
                  let command = clangCommand(for: parts[1], platform: platform, arch: arch) else {
                continue
            }
            // 共同目录层级越深越接近；同语言额外加权，优先保证编译参数（如 -fobjc-arc、-std）一致
            var score = Self.commonDirectoryDepth(parts[1], target) * 2
            if Self.clangLanguage(forPath: parts[1]) == language {
                score += 1
            }
            if best == nil || score > best!.score {
                best = (parts[1], command, score)
            }
        }
        return best.map { ($0.source, $0.command) }
    }

    /// 取模块命令涉及的所有 swift 源文件（含 @filelist）
    public static func swiftSources(of module: RawCompileCommand) -> Set<String> {
        var sources = Set<String>()
        for token in module.tokens {
            if token.hasSuffix(".swift") {
                sources.insert(token)
            } else if token.hasPrefix("@") {
                let listPath = String(token.dropFirst())
                if let content = try? String(contentsOfFile: listPath, encoding: .utf8) {
                    for line in content.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasSuffix(".swift") {
                            sources.insert(trimmed)
                        }
                    }
                }
            }
        }
        return sources
    }

    /// 按扩展名推断 clang 的 -x 语言名
    public static func clangLanguage(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m":
            return "objective-c"
        case "mm":
            return "objective-c++"
        case "c":
            return "c"
        default:
            return "c++"
        }
    }

    /// 两个文件所在目录的共同层级数
    public static func commonDirectoryDepth(_ a: String, _ b: String) -> Int {
        let lhs = (a as NSString).deletingLastPathComponent.split(separator: "/")
        let rhs = (b as NSString).deletingLastPathComponent.split(separator: "/")
        var depth = 0
        while depth < lhs.count, depth < rhs.count, lhs[depth] == rhs[depth] {
            depth += 1
        }
        return depth
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

    /// 解析日志明文。新日志在前，同一 (模块, 平台, 架构) / (文件, 平台, 架构) 只保留最新一条
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
                let arch = RawCompileCommand.arch(forTarget: target) ?? "?"
                let key = "\(moduleName ?? "?")|\(platform)|\(arch)"
                if seenModules.contains(key) {
                    continue
                }
                seenModules.insert(key)
                parsed.swiftModules.append(RawCompileCommand(
                    kind: .swiftModule, tokens: tokens, workingDirectory: currentWorkingDir,
                    moduleName: moduleName, platform: platform, target: target))
                continue
            }
            // ibtool 编译 storyboard / xib 的命令：取最后一个界面文件参数作为源文件
            if line.contains("/ibtool "), line.contains(".storyboard") || line.contains(".xib") {
                let tokens = CommandTokenizer.tokenize(line)
                guard let executable = tokens.first, executable.hasSuffix("/ibtool"),
                      !tokens.contains("--link"),
                      let source = tokens.last(where: { $0.hasSuffix(".storyboard") || $0.hasSuffix(".xib") }) else {
                    continue
                }
                let key = ParsedCommands.canonicalPath(source)
                if parsed.ibtoolCommands[key] == nil {
                    parsed.ibtoolCommands[key] = RawCompileCommand(
                        kind: .ibtool, tokens: tokens, workingDirectory: currentWorkingDir,
                        moduleName: valueForFlag("--module", in: tokens), platform: "unknown", target: nil)
                }
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
                var existing = parsed.clangFiles[key] ?? []
                let arch = RawCompileCommand.arch(forTarget: target)
                // 每个架构只保留最新一条
                if existing.contains(where: { $0.arch == arch }) {
                    continue
                }
                existing.append(RawCompileCommand(
                    kind: .clangFile, tokens: tokens, workingDirectory: currentWorkingDir,
                    moduleName: nil, platform: platform, target: target))
                parsed.clangFiles[key] = existing
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
