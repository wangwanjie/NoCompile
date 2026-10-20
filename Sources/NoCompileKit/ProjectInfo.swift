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

    /// 头文件变更 → 依赖它的实现文件（一次性用法；引擎内请用 HeaderDependencyIndex 以复用索引）
    public static func implementationFiles(dependingOn header: String, derivedDataPath: String) -> [String] {
        return HeaderDependencyIndex(derivedDataPath: derivedDataPath).sources(dependingOn: header)
    }

    /// 工程目录之外、但属于本工程的源码目录：
    /// CocoaPods 以 :path 引用的本地 Pod（Podfile.lock 的 EXTERNAL SOURCES），
    /// 以及 .xcworkspace 引用的、位于工程目录之外的子工程。这些目录同样需要监听
    public static func externalSourceRoots(projectPath: String) -> [String] {
        let projectDirectory = (projectPath as NSString).deletingLastPathComponent
        var roots: [String] = []

        // 1. Podfile.lock：  :path: "../Modules/Foo" 或绝对路径（相对路径以 Podfile 所在目录为基准）
        let lockPath = (projectDirectory as NSString).appendingPathComponent("Podfile.lock")
        if let content = try? String(contentsOfFile: lockPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(":path:") else {
                    continue
                }
                var value = String(trimmed.dropFirst(":path:".count)).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !value.isEmpty else {
                    continue
                }
                roots.append(absolute(value, relativeTo: projectDirectory))
            }
        }

        // 2. workspace 引用的子工程：<FileRef location = "group:../Other/Other.xcodeproj">
        if projectPath.hasSuffix(".xcworkspace") {
            let dataPath = (projectPath as NSString).appendingPathComponent("contents.xcworkspacedata")
            if let content = try? String(contentsOfFile: dataPath, encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #"location\s*=\s*"(group|absolute|container):([^"]+)""#) {
                let range = NSRange(content.startIndex..., in: content)
                for match in regex.matches(in: content, range: range) {
                    guard let kindRange = Range(match.range(at: 1), in: content),
                          let pathRange = Range(match.range(at: 2), in: content) else {
                        continue
                    }
                    let kind = String(content[kindRange])
                    let path = String(content[pathRange])
                    let resolved = kind == "absolute" ? path : absolute(path, relativeTo: projectDirectory)
                    // 引用的是 .xcodeproj 时监听它所在的目录
                    let directory = resolved.hasSuffix(".xcodeproj") ? (resolved as NSString).deletingLastPathComponent : resolved
                    roots.append(directory)
                }
            }
        }

        // 只保留真实存在、且不在工程目录内的目录；去掉彼此包含的重复项
        let fm = FileManager.default
        let base = ParsedCommands.canonicalPath(projectDirectory)
        var result: [String] = []
        for root in roots.map({ ParsedCommands.canonicalPath($0) }).sorted() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // 防止误把家目录、根目录整个监听
            guard root != "/", root != NSHomeDirectory(), root.split(separator: "/").count >= 3 else {
                continue
            }
            if isPath(root, inside: base) || result.contains(where: { isPath(root, inside: $0) }) {
                continue
            }
            result.append(root)
        }
        return result
    }

    static func absolute(_ path: String, relativeTo base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    static func isPath(_ path: String, inside directory: String) -> Bool {
        return path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    private static var sdkPathCache: [String: String] = [:]
    private static let sdkPathLock = NSLock()

    /// 为平台名解析 SDK 路径。结果缓存：每次注入都要查询，每次都起 xcrun 子进程开销不小
    public static func sdkPath(for platformName: String) -> String? {
        sdkPathLock.lock()
        let cached = sdkPathCache[platformName]
        sdkPathLock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let result = Shell.run("/usr/bin/xcrun", ["--sdk", platformName, "--show-sdk-path"], timeout: 30)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            Diagnostics.shared.log("SDK", "无法定位 \(platformName) SDK：\(result.stderr)", level: .error)
            return nil
        }
        sdkPathLock.lock()
        sdkPathCache[platformName] = path
        sdkPathLock.unlock()
        return path
    }
}

/// 头文件 → 依赖它的实现文件的反向索引，由 DerivedData 中 clang 生成的 .d 依赖文件建立。
/// 大型工程有上万个 .d 文件（合计上百 MB），每改一个头文件都全量扫描一遍会非常慢；
/// 这里只扫描一次建立索引，构建日志更新（即重新构建过）后再失效重建
public final class HeaderDependencyIndex {

    private let intermediates: String

    /// 一份完整的索引。扫描在锁外进行，完成后整体替换
    private struct Snapshot {
        /// 头文件路径 → 实现文件序号
        var headerToSources: [String: [Int32]] = [:]
        var sources: [String] = []
        /// 显式模块构建（Xcode 16+ 默认）下，源文件的 .d 里只列出所依赖模块的 .pcm，不列模块里的头文件；
        /// 头文件列在模块自己的 .d 里。这里记录 头文件 → 模块、模块 → 依赖它的实现文件，两级查找
        var headerToModules: [String: [String]] = [:]
        var moduleToSources: [String: [Int32]] = [:]
    }

    /// condition 同时充当锁：保护 snapshot / generation / building
    private let condition = NSCondition()
    private var snapshot: Snapshot?
    /// 失效计数：invalidate() 只把它加一，正在进行的扫描结束时发现计数变了就丢弃结果
    private var generation = 0
    private var snapshotGeneration = -1
    /// 正在扫描的代数；其他查询者等它完成，避免同时扫描两遍
    private var buildingGeneration: Int?

    private static let implementationExtensions: Set<String> = ["m", "mm", "c", "cpp", "cc", "cxx", "swift"]

    public init(derivedDataPath: String) {
        self.intermediates = "\(derivedDataPath)/Build/Intermediates.noindex"
    }

    /// 标记失效，下次查询时重建。不等待正在进行的扫描，不会阻塞调用方
    public func invalidate() {
        condition.lock()
        generation += 1
        condition.unlock()
    }

    /// 取最新的索引：已是最新直接返回；同一代正在扫描就等它；否则在锁外扫描
    private func currentSnapshot() -> Snapshot {
        condition.lock()
        while true {
            if let snapshot, snapshotGeneration == generation {
                condition.unlock()
                return snapshot
            }
            if buildingGeneration == generation {
                condition.wait()
                continue
            }
            break
        }
        let target = generation
        buildingGeneration = target
        condition.unlock()

        let built = Self.build(intermediates: intermediates)

        condition.lock()
        // 扫描期间又失效了（重新构建过）：结果仍可用于本次查询，但不缓存
        if generation == target {
            snapshot = built
            snapshotGeneration = target
        }
        if buildingGeneration == target {
            buildingGeneration = nil
        }
        condition.broadcast()
        condition.unlock()
        return built
    }

    /// 依赖该头文件、且仍存在的实现文件
    public func sources(dependingOn header: String) -> [String] {
        let index = currentSnapshot()
        var ids = Set<Int32>()
        for key in Set([header, ParsedCommands.canonicalPath(header)]) {
            ids.formUnion(index.headerToSources[key] ?? [])
            for module in index.headerToModules[key] ?? [] {
                ids.formUnion(index.moduleToSources[module] ?? [])
            }
        }
        let fm = FileManager.default
        return ids.map { index.sources[Int($0)] }.filter { fm.fileExists(atPath: $0) }.sorted()
    }

    /// 构建产物目录里与某头文件同名的副本（framework 的 Headers 目录等）。
    /// Xcode 把 framework 的公开头文件复制到构建产物里，使用方 `#import <Foo/Foo.h>` 读到的是副本，
    /// 副本只在下次完整构建时才会更新，所以改了源头文件后要同步副本，使用方重编时才能看到改动
    public func productCopies(ofHeaderNamed name: String) -> [String] {
        return currentSnapshot().headerToSources.keys.filter {
            ($0 as NSString).lastPathComponent == name
                && ($0.contains("/Build/Products/") || $0.contains("/Intermediates.noindex/"))
        }.sorted()
    }

    /// 被超过 threshold 个实现文件引用的头文件（公共头文件、PCH 引入的头文件等），不含构建产物里的副本
    public func widelyUsedHeaders(threshold: Int) -> [String] {
        return currentSnapshot().headerToSources.filter {
            $0.value.count > threshold && !$0.key.contains("/DerivedData/") && !$0.key.contains("/Build/Products/")
        }.map { $0.key }
    }

    /// 扫描全部 .d 文件建立索引（不持锁，可能耗时数秒）
    private static func build(intermediates: String) -> Snapshot {
        let start = Date()
        var index = Snapshot()
        var sourceIDs: [String: Int32] = [:]
        var canonical: [String: String] = [:]
        var fileCount = 0
        let url = URL(fileURLWithPath: intermediates)
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var dFiles: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "d" {
                dFiles.append(item)
            }
        }
        // 第一遍：显式模块的 .d（目标名是 moduledependenciestarget，依赖里是该模块的头文件）。
        // 先处理它们，才能知道哪些 .pcm 值得在源文件的 .d 里记录
        var knownModules = Set<String>()
        for item in dFiles where item.path.contains("/ExplicitPrecompiledModules/") {
            guard let data = try? Data(contentsOf: item) else {
                continue
            }
            fileCount += 1
            let module = item.deletingPathExtension().appendingPathExtension("pcm").path
            for dep in dependencies(in: data) where !isSystemPath(dep) && !dep.hasSuffix(".pcm") && !dep.hasSuffix(".modulemap") {
                index.headerToModules[ParsedCommands.canonicalPath(dep), default: []].append(module)
                knownModules.insert(module)
            }
        }
        for item in dFiles where !item.path.contains("/ExplicitPrecompiledModules/") {
            guard let data = try? Data(contentsOf: item) else {
                continue
            }
            fileCount += 1
            let deps = dependencies(in: data)
            // 被编译的源文件：与 .d 同名的实现文件（Xcode 27 的 .d 首个依赖是 SDKSettings.json，不能直接取第一个），
            // 没有同名的再取第一个实现文件；都没有则跳过
            let stem = item.deletingPathExtension().lastPathComponent
            let implementations = deps.filter {
                implementationExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }
            guard let primary = implementations.first(where: {
                (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == stem
            }) ?? implementations.first else {
                continue
            }
            let id: Int32
            if let existing = sourceIDs[primary] {
                id = existing
            } else {
                id = Int32(index.sources.count)
                index.sources.append(primary)
                sourceIDs[primary] = id
            }
            for dep in deps where dep.hasSuffix(".pcm") && knownModules.contains(dep) {
                index.moduleToSources[dep, default: []].append(id)
            }
            for dep in deps where dep != primary && !isSystemPath(dep) && !isImplementation(dep) {
                // CocoaPods 的 Pods/Headers 下是指向 Pod 源码的符号链接，.d 里记录的是链接路径，
                // 而文件监听给出的是真实路径：统一规范化后再建索引
                let key: String
                if let memo = canonical[dep] {
                    key = memo
                } else {
                    key = ParsedCommands.canonicalPath(dep)
                    canonical[dep] = key
                }
                index.headerToSources[key, default: []].append(id)
            }
        }
        Diagnostics.shared.log("头文件索引", "扫描 \(fileCount) 个 .d 文件，\(index.sources.count) 个实现文件、\(index.headerToSources.count) 个头文件，"
            + "用时 \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        return index
    }

    private static func isImplementation(_ path: String) -> Bool {
        return implementationExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// SDK、工具链里的系统头文件不会被用户修改，不进索引以节省内存
    private static func isSystemPath(_ path: String) -> Bool {
        // 只做前后缀判断：Foundation 的 contains 在百万次调用下很慢，SDK / 工具链都位于这两个目录下
        return path.hasPrefix("/Applications/") || path.hasPrefix("/Library/Developer/") || path.hasSuffix(".pcm")
    }

    /// 解析 Makefile 依赖格式："目标: 依赖1 依赖2 \\\n 依赖3"，空格以 "\\ " 转义。返回所有依赖（不含目标）
    static func dependencies(in data: Data) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        var seenColon = false
        let applicationsPrefix = Array("/Applications/".utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            let count = bytes.count
            func flush() {
                if !current.isEmpty {
                    // 系统路径（Xcode、SDK）占依赖的大半，按字节前缀直接跳过，省去字符串创建
                    if seenColon, !current.starts(with: applicationsPrefix) {
                        result.append(String(decoding: current, as: UTF8.self))
                    }
                    current.removeAll(keepingCapacity: true)
                }
            }
            while index < count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\\"), index + 1 < count {
                    let next = bytes[index + 1]
                    if next == 0x0A || next == 0x0D {
                        // 续行
                        flush()
                        index += 2
                        continue
                    }
                    if next == 0x20 || next == UInt8(ascii: "#") || next == UInt8(ascii: "\\") {
                        current.append(next)
                        index += 2
                        continue
                    }
                }
                if byte == UInt8(ascii: "$"), index + 1 < count, bytes[index + 1] == UInt8(ascii: "$") {
                    current.append(byte)
                    index += 2
                    continue
                }
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    if !seenColon, current.last == UInt8(ascii: ":") {
                        // "目标:" 结束
                        current.removeAll(keepingCapacity: true)
                        seenColon = true
                    } else {
                        flush()
                    }
                    index += 1
                    continue
                }
                current.append(byte)
                index += 1
            }
            if !seenColon, current.last == UInt8(ascii: ":") {
                current.removeAll()
            }
            flush()
        }
        return result
    }
}
