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
    /// 大型工程的清单可达数百 MB，整体交给 JSONSerialization 会占用数 GB 内存，所以按字节切分条目
    static func parseCompileTasks(manifestPath: String) -> [CompileTask] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath), options: .alwaysMapped) else {
            return []
        }
        var tasks: [CompileTask] = []
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
        return tasks
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
        return CompileTask(source: source, output: output, resp: resp, platform: platform, arch: arch, language: language)
    }

    /// 由中间产物路径推断平台：".../Debug-iphoneos/Foo.build/Objects-normal/arm64/X.o" → iphoneos。
    /// macOS 的配置目录不带平台后缀（Debug / Release）
    static func platform(ofIntermediatePath path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard let buildIndex = components.lastIndex(where: { $0.hasSuffix(".build") }), buildIndex > 0 else {
            return nil
        }
        let configuration = components[buildIndex - 1]
        if let dash = configuration.lastIndex(of: "-") {
            let suffix = String(configuration[configuration.index(after: dash)...])
            let known: Set<String> = ["iphoneos", "iphonesimulator", "macosx", "maccatalyst", "appletvos", "appletvsimulator"]
            return known.contains(suffix) ? suffix : nil
        }
        // 无后缀：macOS 构建（Debug / Release / 自定义配置名）。归档路径里的配置目录同样落在这一类
        return "macosx"
    }

    // MARK: - 合成命令

    /// 把清单里的 CompileC 任务合成为 clang 命令，补进 commands 里还没有真实命令的文件，返回补全后的结果与新增条数。
    /// 合成命令借用真实命令作模板：优先同一份 resp（同 target 同架构，-target / -isysroot 精确一致），
    /// 其次同平台同架构的任意一条（部署版本可能与该 target 略有出入，不影响单文件编译；其前缀头文件与警告开关属于模板的 target，会被替换或去掉）。
    /// 上次合成的命令（synthesized）会被本次结果覆盖，避免 resp 路径随构建参数变化后残留过期命令
    static func fill(_ commands: ParsedCommands, with tasks: [CompileTask],
                     fallbackWorkingDirectory: String) -> (commands: ParsedCommands, added: Int) {
        var byResp: [String: RawCompileCommand] = [:]
        var byPlatformArch: [String: RawCompileCommand] = [:]
        for command in commands.allClangCommands where command.synthesized != true {
            if let resp = respPath(in: command.tokens), byResp[resp] == nil {
                byResp[resp] = command
            }
            let key = "\(command.platform)|\(command.arch ?? "?")"
            if byPlatformArch[key] == nil {
                byPlatformArch[key] = command
            }
        }
        var result = commands
        var added = 0
        var refreshed = Set<String>()
        for task in tasks {
            let sameTarget = task.resp.flatMap { byResp[$0] }
            guard let template = sameTarget ?? byPlatformArch["\(task.platform)|\(task.arch)"] else {
                continue
            }
            let key = ParsedCommands.clangKey(platform: task.platform, source: task.source)
            var existing = result.clangFiles[key] ?? []
            // 已有真实命令：以真实命令为准
            if existing.contains(where: { $0.arch == task.arch && $0.synthesized != true }) {
                continue
            }
            // 同一次填充里先出现的清单（更新的构建）优先，后面的清单不再覆盖
            let refreshKey = "\(key)|\(task.arch)"
            if refreshed.contains(refreshKey) {
                continue
            }
            refreshed.insert(refreshKey)
            if existing.contains(where: { $0.arch == task.arch }) {
                existing.removeAll { $0.arch == task.arch }
            } else {
                added += 1
            }
            var command = RawCompileCommand(
                kind: .clangFile,
                tokens: rewrite(template: template.tokens, task: task, sameTarget: sameTarget != nil),
                workingDirectory: template.workingDirectory.isEmpty ? fallbackWorkingDirectory : template.workingDirectory,
                moduleName: nil, platform: task.platform, target: template.target)
            command.synthesized = true
            existing.append(command)
            result.clangFiles[key] = existing
        }
        return (result, added)
    }

    private static func respPath(in tokens: [String]) -> String? {
        guard let token = tokens.first(where: { $0.hasPrefix("@") && $0.hasSuffix(".resp") }) else {
            return nil
        }
        return String(token.dropFirst())
    }

    /// CocoaPods 的前缀头文件固定放在 "<Pods>/Target Support Files/<Target>/<Target>-prefix.pch"。
    /// 由模板里的 -include 路径找到 Pods 目录，再按本任务的 target 名拼出对应的前缀头文件，文件存在才返回
    private static func ownPrefixHeader(templateValue: String, task: CompileTask) -> String? {
        guard let range = templateValue.range(of: "/Target Support Files/"),
              let name = targetName(ofIntermediatePath: task.output) else {
            return nil
        }
        let candidate = "\(templateValue[..<range.upperBound])\(name)/\(name)-prefix.pch"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// ".../KGCommontools.build/Objects-normal/arm64/X.o" → KGCommontools
    static func targetName(ofIntermediatePath path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard let index = components.lastIndex(of: "Objects-normal"), index > 0,
              components[index - 1].hasSuffix(".build") else {
            return nil
        }
        return String(components[index - 1].dropLast(".build".count))
    }

    /// 以模板命令为底，换上该任务自己的 resp / 源文件 / 输出 / 语言。
    /// 模板来自其他 target 时，去掉 -include / -include-pch：前缀头文件属于模板所在的 target，借给别的 target 会找错头文件
    private static func rewrite(template: [String], task: CompileTask, sameTarget: Bool) -> [String] {
        var tokens: [String] = []
        var index = 0
        while index < template.count {
            let token = template[index]
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
                // 前缀头文件属于模板所在的 target：能按 CocoaPods 的命名规则换成本 target 的就换，找不到就去掉
                if token == "-include", let own = ownPrefixHeader(templateValue: template[index + 1], task: task) {
                    tokens.append(contentsOf: ["-include", own])
                }
                index += 2
                continue
            }
            // 警告开关不影响产物，但模板里的 -Werror=... 在别的 target 下可能把警告升级成错误（如 framework 模块才有的 non-modular 检查）
            if !sameTarget, token.hasPrefix("-W") {
                index += 1
                continue
            }
            if token.hasPrefix("@"), token.hasSuffix(".resp"), let resp = task.resp {
                tokens.append("@" + resp)
                index += 1
                continue
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }
}
