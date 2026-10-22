//
//  BuildManifest.swift
//  从 Xcode 的构建清单（XCBuildData/*.xcbuilddata/manifest.json）补全 clang 编译命令。
//
//  背景：xcactivitylog 只记录某次构建实际执行的任务。完整构建的日志被后续增量构建挤掉后，
//  日志里只剩被改动过的少数文件，其余文件（如 Pods 里成千上万个 .m）没有命令可用。
//  manifest.json 保存的是最近一次构建描述里的全部任务，不会被清理：
//  每个 CompileC 任务都带有源文件、.o 输出路径与共享参数文件（common-args.resp）。
//  清单里没有完整命令行（-target、-isysroot 等在 task-store.msgpack 里），
//  所以这里借用日志里同一 target（同一份 resp）或同平台同架构的已有命令作模板，
//  替换其中的 resp / 源文件 / 输出 / 语言，合成出该文件的命令。
//  合成的命令优先级最低：日志里有真实命令的文件始终以真实命令为准。
//

import Foundation

enum BuildManifest {

    /// 清单里的一条 CompileC 任务
    struct CompileTask {
        let source: String
        let output: String
        /// 该 target 的共享参数文件（common-args.resp）
        let resp: String?
        let platform: String
        let arch: String
        /// clang 的 -x 语言名：objective-c / objective-c++ / c / c++
        let language: String
        /// 该 target 的前缀头文件（GCC_PREFIX_HEADER），没有为 nil
        let prefixHeader: String?
    }

    /// DerivedData 下所有清单文件，按修改时间从新到旧
    static func manifestFiles(derivedDataPath: String) -> [String] {
        let root = "\(derivedDataPath)/Build/Intermediates.noindex/XCBuildData"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return entries.filter { $0.hasSuffix(".xcbuilddata") }
            .map { "\(root)/\($0)/manifest.json" }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted { BuildLog.modificationDate(of: $0) > BuildLog.modificationDate(of: $1) }
    }

    /// 清单的指纹（修改时间 + 大小）：同一目录下的清单会被 Xcode 原地重写，只看路径不够
    static func fingerprint(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(Int64(date))|\(size)"
    }

    // MARK: - 解析清单

    private static let commandsMarker = Array("\"commands\":{".utf8)
    private static let compileMarker = Array(":CompileC ".utf8)
    private static let sourceExtensions = [".m", ".mm", ".c", ".cpp", ".cc", ".cxx"]

    /// 流式扫描清单里的 commands 对象，只对 CompileC 任务做 JSON 解码。
    /// 大型工程的清单可达数百 MB，整体交给 JSONSerialization 会占用数 GB 内存，所以按字节切分条目。
    /// complete 表示读到了 commands 的结尾；Xcode 正在改写清单时可能只读到一部分。
    /// 整体读入内存而不是 mmap：映射期间文件被截断重写会触发 SIGBUS 让 NoCompile 崩溃
    static func parseCompileTasks(manifestPath: String) -> (tasks: [CompileTask], complete: Bool) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else {
            return ([], false)
        }
        var tasks: [CompileTask] = []
        var complete = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return
            }
            let total = bytes.count
            let found = commandsMarker.withUnsafeBufferPointer { pattern -> Int? in
                guard let hit = memmem(base, total, pattern.baseAddress!, pattern.count) else {
                    return nil
                }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + pattern.count
            }
            guard var index = found else {
                return
            }
            while index < total {
                // 跳过条目之间的逗号与空白；遇到 } 表示 commands 结束
                while index < total, bytes[index] == UInt8(ascii: ",") || bytes[index] == 0x20 || bytes[index] == 0x0A {
                    index += 1
                }
                guard index < total, bytes[index] == UInt8(ascii: "\"") else {
                    complete = index < total && bytes[index] == UInt8(ascii: "}")
                    return
                }
                let keyStart = index + 1
                guard let keyEnd = endOfString(bytes, from: keyStart) else {
                    return
                }
                index = keyEnd + 1
                guard index < total, bytes[index] == UInt8(ascii: ":") else {
                    return
                }
                index += 1
                guard index < total, bytes[index] == UInt8(ascii: "{") else {
                    return
                }
                let valueStart = index
                guard let valueEnd = endOfObject(bytes, from: valueStart) else {
                    return
                }
                index = valueEnd + 1
                let keyBytes = UnsafeBufferPointer(rebasing: bytes[keyStart ..< keyEnd])
                guard LogLineParser.find(compileMarker, in: keyBytes) != nil else {
                    continue
                }
                let key = String(decoding: keyBytes, as: UTF8.self)
                let value = Data(bytes: base + valueStart, count: valueEnd - valueStart + 1)
                if let task = compileTask(key: key, value: value) {
                    tasks.append(task)
                }
            }
        }
        return (tasks, complete)
    }

    /// 字符串结束引号的位置（from 指向开头引号之后的第一个字节），处理反斜杠转义
    private static func endOfString(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte == UInt8(ascii: "\"") {
                return index
            }
            index += 1
        }
        return nil
    }

    /// 对象结束括号的位置（from 指向开头的 {），跳过字符串里的括号
    private static func endOfObject(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                guard let end = endOfString(bytes, from: index + 1) else {
                    return nil
                }
                index = end + 1
                continue
            }
            if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    /// 解码一条 CompileC 任务。
    /// key 形如 "P1:target-X-hash-:Release:CompileC <.o> <源文件> normal arm64 objective-c com.apple...compiler"，
    /// 路径可能含空格，所以架构 / 语言从末尾倒着取，源文件与输出取自 inputs / outputs
    private static func compileTask(key: String, value: Data) -> CompileTask? {
        guard let range = key.range(of: ":CompileC ") else {
            return nil
        }
        let tail = key[range.upperBound...].split(separator: " ").map(String.init)
        // 末尾四项：normal <arch> <lang> <compiler>
        guard tail.count >= 6, tail[tail.count - 4] == "normal" else {
            return nil
        }
        let arch = tail[tail.count - 3]
        let language = tail[tail.count - 2]
        guard let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let inputs = object["inputs"] as? [String],
              let outputs = object["outputs"] as? [String],
              let output = outputs.first,
              let source = inputs.first(where: { input in
                  input.hasPrefix("/") && sourceExtensions.contains(where: { input.hasSuffix($0) })
              }) else {
            return nil
        }
        guard let platform = platform(ofIntermediatePath: output) else {
            return nil
        }
        let resp = inputs.first(where: { $0.hasSuffix(".resp") })
        let prefixHeader = inputs.first(where: { $0.hasSuffix(".pch") })
        return CompileTask(source: source, output: output, resp: resp, platform: platform, arch: arch,
                           language: language, prefixHeader: prefixHeader)
    }

    /// 中间产物路径里的配置目录：".../Debug-iphoneos/Foo.build/Objects-normal/arm64/X.o" → Debug-iphoneos
    static func configurationDirectory(ofIntermediatePath path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard let buildIndex = components.lastIndex(where: { $0.hasSuffix(".build") }), buildIndex > 0 else {
            return nil
        }
        return components[buildIndex - 1]
    }

    /// 由中间产物路径推断平台：".../Debug-iphoneos/Foo.build/Objects-normal/arm64/X.o" → iphoneos。
    /// macOS 的配置目录不带平台后缀（Debug / Release，或 Debug-Staging 这类带连字符的自定义配置名）
    static func platform(ofIntermediatePath path: String) -> String? {
        guard let configuration = configurationDirectory(ofIntermediatePath: path) else {
            return nil
        }
        if let dash = configuration.lastIndex(of: "-") {
            let suffix = String(configuration[configuration.index(after: dash)...])
            if ParsedCommands.knownPlatformDirectorySuffixes.contains(suffix) {
                return RawCompileCommand.normalizedPlatform(suffix)
            }
        }
        // 无平台后缀：macOS 构建。归档路径里的配置目录同样落在这一类
        return "macosx"
    }

    // MARK: - 合成命令

    /// 把清单里的 CompileC 任务合成为 clang 命令，补进 commands 里还没有真实命令的文件，返回补全后的结果与新增条数。
    /// 合成命令借用真实命令作模板：
    /// 1. 优先同一份 resp（同 target 同架构同语言，-target / -isysroot 精确一致）；
    /// 2. 其次同平台、同架构、同配置目录（如 Debug-iphonesimulator）的任意一条。跨 target 借用时，前缀头文件换成本任务自己的，
    ///    警告开关去掉；配置目录必须一致，避免用 Release 的参数编译 Debug 运行中的代码。
    /// 模板里 Xcode 追加的文件级参数（如 -fno-objc-arc）属于模板文件自己，一律去掉。
    /// 上次合成的命令（synthesized）会被本次结果覆盖，避免 resp 路径随构建参数变化后残留过期命令
    static func fill(_ commands: ParsedCommands, with tasks: [CompileTask],
                     fallbackWorkingDirectory: String) -> (commands: ParsedCommands, added: Int) {
        var byResp: [String: RawCompileCommand] = [:]
        var byConfiguration: [String: RawCompileCommand] = [:]
        for command in commands.allClangCommands where command.synthesized != true {
            // 同一键下优先选没有文件级参数的命令，模板越「干净」越不容易把别的文件的特殊参数带过去
            let clean = ClangCommandEditing.fileLevelFlags(in: command.tokens).isEmpty
            if let resp = ClangCommandEditing.respPath(in: command.tokens) {
                if byResp[resp] == nil || (clean && !ClangCommandEditing.fileLevelFlags(in: byResp[resp]!.tokens).isEmpty) {
                    byResp[resp] = command
                }
            }
            guard let output = ClangCommandEditing.value(after: "-o", in: command.tokens),
                  let configuration = configurationDirectory(ofIntermediatePath: output) else {
                continue
            }
            let key = "\(command.platform)|\(command.arch ?? "?")|\(configuration)"
            if byConfiguration[key] == nil || (clean && !ClangCommandEditing.fileLevelFlags(in: byConfiguration[key]!.tokens).isEmpty) {
                byConfiguration[key] = command
            }
        }
        var result = commands
        var added = 0
        var refreshed = Set<String>()

        func apply(_ task: CompileTask, template: RawCompileCommand, sameTarget: Bool) {
            let key = ParsedCommands.clangKey(platform: task.platform, source: task.source)
            var existing = result.clangFiles[key] ?? []
            // 已有真实命令：以真实命令为准
            if existing.contains(where: { $0.arch == task.arch && $0.synthesized != true }) {
                return
            }
            // 同一次填充里先处理的（同 target 模板优先，其次更新的清单）为准，后面的不再覆盖
            let refreshKey = "\(key)|\(task.arch)"
            guard refreshed.insert(refreshKey).inserted else {
                return
            }
            if existing.contains(where: { $0.arch == task.arch }) {
                existing.removeAll { $0.arch == task.arch }
            } else {
                added += 1
            }
            var command = RawCompileCommand(
                kind: .clangFile,
                tokens: rewrite(template: template.tokens, task: task, sameTarget: sameTarget),
                workingDirectory: template.workingDirectory.isEmpty ? fallbackWorkingDirectory : template.workingDirectory,
                moduleName: nil, platform: task.platform, target: template.target)
            command.synthesized = true
            existing.append(command)
            result.clangFiles[key] = existing
        }

        // 第一遍：能找到同 target 模板的任务
        var crossTarget: [CompileTask] = []
        for task in tasks {
            if let resp = task.resp, let template = byResp[resp] {
                apply(task, template: template, sameTarget: true)
            } else {
                crossTarget.append(task)
            }
        }
        // 第二遍：借用同平台、同架构、同配置目录的其他 target 的命令。没有 resp 的任务拿不到 -I / -D，跳过
        for task in crossTarget where task.resp != nil {
            guard let configuration = configurationDirectory(ofIntermediatePath: task.output),
                  let template = byConfiguration["\(task.platform)|\(task.arch)|\(configuration)"],
                  ClangCommandEditing.respPath(in: template.tokens) != nil else {
                continue
            }
            apply(task, template: template, sameTarget: false)
        }
        return (result, added)
    }

    /// 以模板命令为底，换上该任务自己的 resp / 源文件 / 输出 / 语言，去掉模板文件自己的文件级参数。
    /// 模板来自其他 target 时，前缀头文件换成本任务的（没有就去掉），警告开关去掉
    private static func rewrite(template: [String], task: CompileTask, sameTarget: Bool) -> [String] {
        var tokens: [String] = []
        var index = 0
        var skippingFileFlags = false
        while index < template.count {
            let token = template[index]
            if skippingFileFlags {
                if !ClangCommandEditing.fileFlagsTerminators.contains(token) {
                    index += 1
                    continue
                }
                skippingFileFlags = false
            }
            if token == "-c", index + 1 < template.count {
                tokens.append(contentsOf: ["-c", task.source])
                index += 2
                continue
            }
            if token == "-o", index + 1 < template.count {
                tokens.append(contentsOf: ["-o", task.output])
                index += 2
                continue
            }
            if token == "-x", index + 1 < template.count {
                tokens.append(contentsOf: ["-x", task.language])
                index += 2
                continue
            }
            if !sameTarget, token == "-include" || token == "-include-pch", index + 1 < template.count {
                // 前缀头文件属于模板所在的 target，已在 resp 之后换成本任务自己的
                index += 2
                continue
            }
            // 警告开关不影响产物，但模板里的 -Werror=... 在别的 target 下可能把警告升级成错误（如 framework 模块才有的 non-modular 检查）
            if !sameTarget, token.hasPrefix("-W") {
                index += 1
                continue
            }
            if token.hasPrefix("@"), token.hasSuffix(".resp") {
                tokens.append("@" + (task.resp ?? String(token.dropFirst())))
                if !sameTarget, let prefixHeader = task.prefixHeader {
                    tokens.append(contentsOf: ["-include", prefixHeader])
                }
                skippingFileFlags = true
                index += 1
                continue
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }
}

/// clang 命令的通用编辑：Xcode 的 CompileC 命令形如
/// `clang -x <语言> -target … @<common-args.resp> <文件级参数> -include <前缀头> -MMD -MT … -c <源文件> -o <输出>`，
/// resp 里是 target 级参数（-D、-I、-std、-fobjc-arc 等），resp 之后、-include / -MMD 等之前是该文件单独设置的参数
enum ClangCommandEditing {

    /// 文件级参数段的结束标记
    static let fileFlagsTerminators: Set<String> = [
        "-include", "-include-pch", "-MMD", "-MD", "-MT", "-MF", "--serialize-diagnostics",
        "-c", "-o", "-index-unit-output-path", "-index-store-path", "-fsyntax-only",
    ]

    /// 命令引用的 resp 参数文件路径
    static func respPath(in tokens: [String]) -> String? {
        guard let token = tokens.first(where: { $0.hasPrefix("@") && $0.hasSuffix(".resp") }) else {
            return nil
        }
        return String(token.dropFirst())
    }

    /// resp 之后的文件级参数
    static func fileLevelFlags(in tokens: [String]) -> [String] {
        guard let start = tokens.firstIndex(where: { $0.hasPrefix("@") && $0.hasSuffix(".resp") }) else {
            return []
        }
        var flags: [String] = []
        for token in tokens[(start + 1)...] {
            if fileFlagsTerminators.contains(token) {
                break
            }
            flags.append(token)
        }
        return flags
    }

    /// 去掉文件级参数
    static func removingFileLevelFlags(_ tokens: [String]) -> [String] {
        guard let start = tokens.firstIndex(where: { $0.hasPrefix("@") && $0.hasSuffix(".resp") }) else {
            return tokens
        }
        let count = fileLevelFlags(in: tokens).count
        var result = tokens
        result.removeSubrange((start + 1) ..< (start + 1 + count))
        return result
    }

    /// 参数的值（如 "-o" 之后的路径）
    static func value(after flag: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else {
            return nil
        }
        return tokens[index + 1]
    }
}
