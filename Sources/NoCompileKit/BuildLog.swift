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
public struct RawCompileCommand: Codable {
    public enum Kind: String, Codable {
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
    /// 由构建清单（manifest.json）借用模板合成的命令，而非日志里的真实命令；旧缓存里没有该字段
    public var synthesized: Bool? = nil

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
        // watchOS / visionOS（如 iOS 工程里的 Watch App）单独归类，不能混进 iOS 的命令里被 iOS 客户端选中。
        // tvOS 与 iOS 客户端上报的平台名相同，仍按 iOS 归类
        let os = target.split(separator: "-").dropFirst(2).first ?? ""
        if os.hasPrefix("watchos") {
            return target.hasSuffix("-simulator") ? "watchsimulator" : "watchos"
        }
        if os.hasPrefix("xros") || os.hasPrefix("visionos") {
            return target.hasSuffix("-simulator") ? "xrsimulator" : "xros"
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
public struct ParsedCommands: Codable {
    /// Swift 模块命令（同一模块在不同平台、不同架构各一条，新日志在前）
    public var swiftModules: [RawCompileCommand] = []
    /// clang 单文件命令，键为 "平台|源文件绝对路径"，值为各架构的命令（新日志在前，每个架构一条）
    public var clangFiles: [String: [RawCompileCommand]] = [:]

    /// ibtool 命令，键为界面文件的规范化路径。nib 格式与模拟器 / 真机无关，不区分平台
    public var ibtoolCommands: [String: RawCompileCommand] = [:]

    /// 构建时拷贝 / 编译资源与头文件的目标位置：键为源文件（或 .xcassets）的规范化路径，值为构建产物里的路径。
    /// 用来知道一个资源最终落在哪个 bundle（App、framework、资源 bundle）里，以及 framework 头文件的副本在哪
    public var resourceDestinations: [String: String] = [:]

    /// 按平台拆分的资源目标位置：平台 → (源文件 → 构建产物路径)。
    /// 同一份资源被 iOS 与 macOS 两个 App 各拷一份时，resourceDestinations 只留先出现的那个，
    /// 这里把每个平台自己的目标都保留下来。旧版命令缓存里没有该字段，保持 nil
    public var platformResourceDestinations: [String: [String: String]]? = nil

    /// 最近一次构建使用的代码签名身份（真机注入需要）
    public var signingIdentity: String?

    public init() {}

    /// 用较新的解析结果覆盖较旧的：同一 (模块, 平台, 架构)、(文件, 平台, 架构) 以较新的为准。
    /// 增量解析时只解析新出现的日志，再与之前的结果合并，避免每次都重新解析全部日志
    public func merging(older: ParsedCommands) -> ParsedCommands {
        var result = self
        var seenModules = Set(swiftModules.map(Self.moduleKey))
        for command in older.swiftModules {
            if seenModules.insert(Self.moduleKey(command)).inserted {
                result.swiftModules.append(command)
            }
        }
        for (key, commands) in older.clangFiles {
            var merged = result.clangFiles[key] ?? []
            for command in commands where !merged.contains(where: { $0.arch == command.arch }) {
                merged.append(command)
            }
            result.clangFiles[key] = merged
        }
        for (key, command) in older.ibtoolCommands where result.ibtoolCommands[key] == nil {
            result.ibtoolCommands[key] = command
        }
        for (key, value) in older.resourceDestinations where result.resourceDestinations[key] == nil {
            result.resourceDestinations[key] = value
        }
        if let olderByPlatform = older.platformResourceDestinations {
            var byPlatform = result.platformResourceDestinations ?? [:]
            for (platform, destinations) in olderByPlatform {
                var merged = byPlatform[platform] ?? [:]
                for (key, value) in destinations where merged[key] == nil {
                    merged[key] = value
                }
                byPlatform[platform] = merged
            }
            result.platformResourceDestinations = byPlatform
        }
        if result.signingIdentity == nil {
            result.signingIdentity = older.signingIdentity
        }
        return result
    }

    /// 切换成某平台视角：resourceDestinations 换成该平台自己的目标位置，
    /// 这样下游按"有没有拷贝记录""属于哪个 bundle"判断时不会串到其他平台的 App。
    /// 没有按平台记录的数据（旧缓存）时原样返回
    public func scopingResources(to platform: String) -> ParsedCommands {
        guard let byPlatform = platformResourceDestinations, !byPlatform.isEmpty else {
            return self
        }
        var scoped = self
        scoped.resourceDestinations = byPlatform[platform] ?? [:]
        return scoped
    }

    /// 由构建产物路径推断所属平台：".../Build/Products/Debug-iphonesimulator/..." → iphonesimulator，
    /// ".../UninstalledProducts/iphoneos/..." → iphoneos，不带平台后缀的 "Debug" 目录即 macosx
    static func platformOfProductPath(_ path: String) -> String? {
        let components = path.components(separatedBy: "/")
        if let index = components.firstIndex(of: "UninstalledProducts"), index + 1 < components.count {
            return components[index + 1]
        }
        guard let index = components.firstIndex(of: "Products"), index + 1 < components.count else {
            return nil
        }
        let configuration = components[index + 1]
        if let dash = configuration.lastIndex(of: "-") {
            return String(configuration[configuration.index(after: dash)...])
        }
        return "macosx"
    }

    static func moduleKey(_ command: RawCompileCommand) -> String {
        return "\(command.moduleName ?? "?")|\(command.platform)|\(command.arch ?? "?")"
    }

    public static func clangKey(platform: String, source: String) -> String {
        return "\(platform)|\(canonicalPath(source))"
    }

    /// 解析符号链接后的路径。文件监听给出的是真实路径（如 /private/tmp/...），
    /// 构建日志里可能是带符号链接的写法（如 /tmp/...），比较前需统一
    public static func canonicalPath(_ path: String) -> String {
        return CanonicalPathCache.shared.resolve(path)
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

    /// 该文件在构建日志里只出现在其他平台的编译命令中（如 macOS 目标的源文件遇到 iOS 客户端）。
    /// 这类文件不属于该平台的任何目标，不能按"新增文件"借用其他模块的命令去编，调用方应直接跳过该平台
    public func isOnlyBuiltForOtherPlatforms(_ source: String, platform: String) -> Bool {
        if source.hasSuffix(".swift") {
            let canonicalSource = Self.canonicalPath(source)
            var knownElsewhere = false
            for module in swiftModules {
                let sources = Self.swiftSources(of: module)
                guard sources.contains(source) || sources.contains(where: { Self.canonicalPath($0) == canonicalSource }) else {
                    continue
                }
                if module.platform == platform {
                    return false
                }
                knownElsewhere = true
            }
            return knownElsewhere
        }
        if clangFiles[Self.clangKey(platform: platform, source: source)] != nil {
            return false
        }
        let suffix = "|" + Self.canonicalPath(source)
        return clangFiles.keys.contains(where: { $0.hasSuffix(suffix) })
    }

    /// 去掉由构建清单合成的命令，只保留日志里的真实命令（写入命令缓存前使用）
    public func droppingSynthesized() -> ParsedCommands {
        var result = self
        var files: [String: [RawCompileCommand]] = [:]
        for (key, commands) in clangFiles {
            let real = commands.filter { $0.synthesized != true }
            if !real.isEmpty {
                files[key] = real
            }
        }
        result.clangFiles = files
        return result
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
            // 共同目录层级越深越接近；同语言额外加权（相当于近 1.5 级目录），优先保证编译参数（如 -fobjc-arc、-std）一致
            var score = Self.commonDirectoryDepth(parts[1], target) * 2
            if Self.clangLanguage(forPath: parts[1]) == language {
                score += 3
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

        // 1. 显式指定的 DerivedData：既可能是工程自己的目录，也可能是全局根目录
        if let customDerivedData, !customDerivedData.isEmpty {
            if let log = buildLog(forProject: projectPath, inDerivedDataRoot: customDerivedData, exactRoot: true) {
                return log
            }
            if let log = buildLog(forProject: projectPath, inDerivedDataRoot: customDerivedData, exactRoot: false) {
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
            if let log = buildLog(forProject: projectPath, inDerivedDataRoot: root, exactRoot: false) {
                return log
            }
        }
        return nil
    }

    private static func buildLog(forProject projectPath: String, inDerivedDataRoot root: String, exactRoot: Bool) -> BuildLog? {
        let fm = FileManager.default
        let name = URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent
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
        // 不同目录下的同名工程（如两份 Example.xcworkspace）会各有一个 "Example-xxx" 目录：
        // 优先取 info.plist 中 WorkspacePath 与当前工程一致的，避免用错另一份工程的构建日志
        // 登记了其他工程路径的目录一律排除；没有登记（info.plist 缺失）的作为退路
        let target = ParsedCommands.canonicalPath(projectPath)
        let targetDirectory = (target as NSString).deletingLastPathComponent
        var exact: String? = nil
        var sibling: String? = nil
        var unknown: [String] = []
        for dataPath in matched {
            guard let info = NSDictionary(contentsOfFile: "\(dataPath)/info.plist"),
                  let workspace = info["WorkspacePath"] as? String else {
                unknown.append(dataPath)
                continue
            }
            let canonicalWorkspace = ParsedCommands.canonicalPath(workspace)
            if canonicalWorkspace == target {
                exact = dataPath
                break
            }
            // 同目录下的 .xcodeproj 与 .xcworkspace（选了工程文件、却用 workspace 构建）也算同一工程
            if sibling == nil, (canonicalWorkspace as NSString).deletingLastPathComponent == targetDirectory {
                sibling = dataPath
                continue
            }
            Diagnostics.shared.log("定位日志", "跳过同名工程的 DerivedData：\(dataPath)（属于 \(workspace)）", level: .debug)
        }
        if let best = exact ?? sibling ?? unknown.first, let dir = logsDir(in: best) {
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

    /// 逐份流式解析日志（按传入顺序，应为新→旧），不把解压后的明文整体读进内存。
    /// 大型工程单份全量构建日志解压后可超过 1GB，整体读入再按行切分会占用数 GB 内存、耗时数分钟
    public static func parse(logs: [String]) -> ParsedCommands {
        let parser = LogLineParser()
        for log in logs {
            let start = Date()
            parser.beginLog()
            let ok = LineSplitter.forEachLine(ofGzip: log) { line in
                parser.handle(line)
            }
            parser.endLog()
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
            Diagnostics.shared.log("解析日志", "\((log as NSString).lastPathComponent)：\(ok ? "完成" : "gunzip 异常退出")，"
                + "用时 \(elapsed)s，累计 \(parser.parsed.swiftModules.count) 条 Swift 模块命令、\(parser.parsed.clangFiles.count) 条 clang 命令",
                level: ok ? .info : .warning)
        }
        return parser.parsed
    }

    /// 解析全部日志（新→旧）
    public func parseAll() -> ParsedCommands {
        return Self.parse(logs: logFiles())
    }

    /// 解析日志明文（测试与兼容用途）。新日志在前，同一 (模块, 平台, 架构) / (文件, 平台, 架构) 只保留最新一条
    public static func parse(plainText text: String) -> ParsedCommands {
        let parser = LogLineParser()
        parser.beginLog()
        var text = text
        text.withUTF8 { bytes in
            LineSplitter.split(bytes, carry: nil) { parser.handle($0) }
        }
        parser.endLog()
        return parser.parsed
    }

    /// 从 clang 命令里取 `-c` 后的源文件（仅限用户源码扩展名）
    static func clangPrimarySource(in tokens: [String]) -> String? {
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

// MARK: - 路径规范化缓存

/// 规范化路径的缓存。解析日志时上万条命令都要规范化源文件路径，逐级 lstat 开销可观；
/// 同一目录下的文件共享目录的解析结果，文件本身只需一次 lstat 判断是否为符号链接
final class CanonicalPathCache {
    static let shared = CanonicalPathCache()

    private var directories: [String: String] = [:]
    private let lock = NSLock()

    func resolve(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        lock.lock()
        let cached = directories[directory]
        lock.unlock()
        let resolvedDirectory: String
        if let cached {
            resolvedDirectory = cached
        } else {
            resolvedDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            lock.lock()
            directories[directory] = resolvedDirectory
            lock.unlock()
        }
        let candidate = resolvedDirectory == "/" ? "/\(name)" : "\(resolvedDirectory)/\(name)"
        // 文件本身是符号链接时再完整解析一次
        var info = stat()
        if lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        }
        // 与 resolvingSymlinksInPath 行为保持一致：存在时去掉 /private 前缀（/private/tmp → /tmp）
        if candidate.hasPrefix("/private/") {
            return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        }
        return candidate
    }
}

// MARK: - 按行切分

/// 把字节流按 \r / \n 切成行。xcactivitylog 是 SLF 二进制，命令行以 \r 分隔夹在其中
enum LineSplitter {

    private static let maxCarry = 16 * 1024 * 1024

    /// 流式解压 gzip 日志并逐行回调
    static func forEachLine(ofGzip path: String, _ body: (UnsafeBufferPointer<UInt8>) -> Void) -> Bool {
        var carry: [UInt8] = []
        let ok = Shell.stream("/usr/bin/gunzip", ["-c", path]) { chunk in
            split(chunk, carry: &carry, body)
        }
        if !carry.isEmpty {
            carry.withUnsafeBufferPointer { body($0) }
        }
        return ok
    }

    /// 切分一块数据；上一块末尾不完整的行放在 carry 中，与本块开头拼接
    static func split(_ bytes: UnsafeBufferPointer<UInt8>, carry: inout [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let count = bytes.count
        var lineStart = 0
        var index = 0
        while index < count {
            let byte = bytes[index]
            if byte == 0x0A || byte == 0x0D {
                if carry.isEmpty {
                    if index > lineStart {
                        body(UnsafeBufferPointer(rebasing: bytes[lineStart ..< index]))
                    }
                } else {
                    carry.append(contentsOf: bytes[lineStart ..< index])
                    carry.withUnsafeBufferPointer { body($0) }
                    carry.removeAll(keepingCapacity: true)
                }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart < count {
            // 超长的无分隔数据不可能是命令行，丢弃以免占用过多内存
            if carry.count + (count - lineStart) <= maxCarry {
                carry.append(contentsOf: bytes[lineStart ..< count])
            } else {
                carry.removeAll(keepingCapacity: false)
            }
        }
    }

    /// 无 carry 的便捷版本（整块数据）
    static func split(_ bytes: UnsafeBufferPointer<UInt8>, carry: [UInt8]?, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        var local = carry ?? []
        split(bytes, carry: &local, body)
        if !local.isEmpty {
            local.withUnsafeBufferPointer { body($0) }
        }
    }
}

// MARK: - 逐行解析

/// 构建日志的行解析器。先按字节做廉价的关键字预筛，只有可能是命令的行才切分参数
final class LogLineParser {

    private(set) var parsed = ParsedCommands()
    private var seenModules = Set<String>()
    private var currentWorkingDir = NSHomeDirectory()
    /// 当前日志里最后出现的 codesign 身份 / EXPANDED_CODE_SIGN_IDENTITY
    private var identityInLog: String?
    private var expandedIdentityInLog: String?

    private static let swiftDriverMarker = Array("builtin-SwiftDriver -- ".utf8)
    private static let ibtoolMarker = Array("/ibtool ".utf8)
    private static let storyboardMarker = Array(".storyboard".utf8)
    private static let xibMarker = Array(".xib".utf8)
    private static let compileMarker = Array(" -c ".utf8)
    private static let codesignMarker = Array("codesign".utf8)
    private static let signFlagMarker = Array("--sign".utf8)
    private static let expandedIdentityMarker = Array("EXPANDED_CODE_SIGN_IDENTITY=".utf8)
    private static let builtinCopyMarker = Array("builtin-copy".utf8)
    private static let copyPNGMarker = Array("/copypng ".utf8)
    private static let actoolMarker = Array("/actool ".utf8)

    func beginLog() {
        currentWorkingDir = NSHomeDirectory()
        identityInLog = nil
        expandedIdentityInLog = nil
    }

    /// 一份日志解析完毕：日志按新→旧传入，签名身份以最新日志里的为准
    func endLog() {
        if parsed.signingIdentity == nil {
            parsed.signingIdentity = identityInLog ?? expandedIdentityInLog
        }
    }

    func handle(_ raw: UnsafeBufferPointer<UInt8>) {
        // 去掉首尾空格 / 制表符
        var lower = 0
        var upper = raw.count
        while lower < upper, raw[lower] == 0x20 || raw[lower] == 0x09 {
            lower += 1
        }
        while upper > lower, raw[upper - 1] == 0x20 || raw[upper - 1] == 0x09 {
            upper -= 1
        }
        guard upper - lower >= 4 else {
            return
        }
        let line = UnsafeBufferPointer(rebasing: raw[lower ..< upper])

        // cd <目录>：之后的命令在该目录下执行
        if line[0] == UInt8(ascii: "c"), line[1] == UInt8(ascii: "d"), line[2] == 0x20 {
            let dir = UnsafeBufferPointer(rebasing: line[3...])
            let tokens = CommandTokenizer.tokenize(bytes: dir)
            if let first = tokens.first, first.hasPrefix("/") {
                currentWorkingDir = first
            }
            return
        }
        // Swift 模块 driver 命令
        if let offset = Self.find(Self.swiftDriverMarker, in: line) {
            let rest = UnsafeBufferPointer(rebasing: line[(offset + Self.swiftDriverMarker.count)...])
            handleSwiftDriver(CommandTokenizer.tokenize(bytes: rest))
            return
        }
        // 资源 / 头文件的拷贝与编译：记录源文件 → 构建产物的位置
        if line.count > 12, line.starts(with: Self.builtinCopyMarker) {
            handleBuiltinCopy(CommandTokenizer.tokenize(bytes: line))
            return
        }
        if Self.find(Self.copyPNGMarker, in: line) != nil {
            handleCopyPNG(CommandTokenizer.tokenize(bytes: line))
            return
        }
        if Self.find(Self.actoolMarker, in: line) != nil {
            handleActool(CommandTokenizer.tokenize(bytes: line))
            return
        }
        // ibtool 编译 storyboard / xib 的命令
        if Self.find(Self.ibtoolMarker, in: line) != nil,
           Self.find(Self.storyboardMarker, in: line) != nil || Self.find(Self.xibMarker, in: line) != nil {
            handleIBTool(CommandTokenizer.tokenize(bytes: line))
            return
        }
        // 代码签名：记录本日志最后一次使用的身份
        if Self.find(Self.codesignMarker, in: line) != nil, Self.find(Self.signFlagMarker, in: line) != nil {
            let tokens = CommandTokenizer.tokenize(bytes: line)
            if let idx = tokens.firstIndex(of: "--sign"), idx + 1 < tokens.count, tokens[idx + 1] != "-" {
                identityInLog = tokens[idx + 1]
            }
            return
        }
        if let offset = Self.find(Self.expandedIdentityMarker, in: line) {
            let rest = UnsafeBufferPointer(rebasing: line[(offset + Self.expandedIdentityMarker.count)...])
            if let identity = CommandTokenizer.tokenize(bytes: rest).first, !identity.isEmpty, identity != "-" {
                expandedIdentityInLog = identity
            }
            return
        }
        // clang 单文件命令：行首必须就是 clang 可执行文件，排除 builtin-ScanDependencies 等包装行
        if Self.find(Self.compileMarker, in: line) != nil {
            handleClang(CommandTokenizer.tokenize(bytes: line))
        }
    }

    private func handleSwiftDriver(_ tokens: [String]) {
        guard tokens.count > 1 else {
            return
        }
        let moduleName = BuildLog.valueForFlag("-module-name", in: tokens)
        let target = BuildLog.valueForFlag("-target", in: tokens)
        let platform = RawCompileCommand.platform(forTarget: target)
        let arch = RawCompileCommand.arch(forTarget: target) ?? "?"
        let key = "\(moduleName ?? "?")|\(platform)|\(arch)"
        guard seenModules.insert(key).inserted else {
            return
        }
        parsed.swiftModules.append(RawCompileCommand(
            kind: .swiftModule, tokens: tokens, workingDirectory: currentWorkingDir,
            moduleName: moduleName, platform: platform, target: target))
    }

    /// 只记录构建产物目录下的目标，中间产物（Intermediates）不关心
    private func recordDestination(source: String, destination: String) {
        guard destination.contains("/Build/Products/") || destination.contains("/UninstalledProducts/"),
              !source.contains("/DerivedData/"), !source.contains("/Build/Intermediates") else {
            return
        }
        let key = ParsedCommands.canonicalPath(source)
        if parsed.resourceDestinations[key] == nil {
            parsed.resourceDestinations[key] = destination
        }
        if let platform = ParsedCommands.platformOfProductPath(destination) {
            var byPlatform = parsed.platformResourceDestinations ?? [:]
            if byPlatform[platform]?[key] == nil {
                byPlatform[platform, default: [:]][key] = destination
                parsed.platformResourceDestinations = byPlatform
            }
        }
    }

    /// builtin-copy [选项] <源> <目标>：目标可能是目录（拷进去、沿用文件名）或完整文件路径
    private func handleBuiltinCopy(_ tokens: [String]) {
        guard tokens.count >= 3, let first = tokens.first else {
            return
        }
        if first == "builtin-copyStrings" || first.hasSuffix("/builtin-copyStrings") {
            // builtin-copyStrings ... --outdir <目录> -- <源>
            guard let outdir = BuildLog.valueForFlag("--outdir", in: tokens), let source = tokens.last else {
                return
            }
            recordDestination(source: source, destination: (outdir as NSString).appendingPathComponent((source as NSString).lastPathComponent))
            return
        }
        guard first == "builtin-copy" else {
            return
        }
        let source = tokens[tokens.count - 2]
        let destination = tokens[tokens.count - 1]
        guard source.hasPrefix("/"), destination.hasPrefix("/") else {
            return
        }
        // 目标已经是带同名文件的完整路径，或是目录：统一成"产物里的文件路径"
        let name = (source as NSString).lastPathComponent
        let final = (destination as NSString).lastPathComponent == name ? destination : (destination as NSString).appendingPathComponent(name)
        recordDestination(source: source, destination: final)
    }

    /// copypng [选项] <源> <目标>
    private func handleCopyPNG(_ tokens: [String]) {
        guard tokens.count >= 3, tokens[0].hasSuffix("/copypng") else {
            return
        }
        recordDestination(source: tokens[tokens.count - 2], destination: tokens[tokens.count - 1])
    }

    /// actool <xcassets> --compile <bundle 目录> ...
    private func handleActool(_ tokens: [String]) {
        guard tokens.count >= 3, tokens[0].hasSuffix("/actool"),
              let catalog = tokens.dropFirst().first(where: { $0.hasSuffix(".xcassets") }),
              let output = BuildLog.valueForFlag("--compile", in: tokens) else {
            return
        }
        recordDestination(source: catalog, destination: output)
    }

    private func handleIBTool(_ tokens: [String]) {
        guard let executable = tokens.first, executable.hasSuffix("/ibtool"),
              !tokens.contains("--link"),
              let source = tokens.last(where: { $0.hasSuffix(".storyboard") || $0.hasSuffix(".xib") }) else {
            return
        }
        if let compiled = BuildLog.valueForFlag("--compile", in: tokens) {
            recordDestination(source: source, destination: compiled)
        }
        let key = ParsedCommands.canonicalPath(source)
        if parsed.ibtoolCommands[key] == nil {
            parsed.ibtoolCommands[key] = RawCompileCommand(
                kind: .ibtool, tokens: tokens, workingDirectory: currentWorkingDir,
                moduleName: BuildLog.valueForFlag("--module", in: tokens), platform: "unknown", target: nil)
        }
    }

    private func handleClang(_ tokens: [String]) {
        guard let executable = tokens.first,
              executable.hasSuffix("/clang") || executable.hasSuffix("/clang++") || executable == "clang" else {
            return
        }
        guard let source = BuildLog.clangPrimarySource(in: tokens) else {
            return
        }
        let target = BuildLog.valueForFlag("-target", in: tokens)
        let platform = RawCompileCommand.platform(forTarget: target)
        let key = ParsedCommands.clangKey(platform: platform, source: source)
        var existing = parsed.clangFiles[key] ?? []
        let arch = RawCompileCommand.arch(forTarget: target)
        // 每个架构只保留最新一条
        if existing.contains(where: { $0.arch == arch }) {
            return
        }
        existing.append(RawCompileCommand(
            kind: .clangFile, tokens: tokens, workingDirectory: currentWorkingDir,
            moduleName: nil, platform: platform, target: target))
        parsed.clangFiles[key] = existing
    }

    /// 字节子串查找，返回起始偏移
    static func find(_ needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else {
            return nil
        }
        return needle.withUnsafeBufferPointer { pattern -> Int? in
            guard let found = memmem(base, haystack.count, pattern.baseAddress!, pattern.count) else {
                return nil
            }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }
}
