//
//  Recompiler.swift
//  单文件重编：源文件 → .o → dylib → 签名。
//
//  Swift 文件复用日志里的模块 driver 命令，交给官方 swiftc 用 `-###` 展开出
//  per-file 的 frontend 命令，再挑出目标文件那条执行。这样无需手写正则硬拆参数，
//  Xcode 升级改了参数也能自动跟随。
//

import Foundation

public struct RecompileResult {
    public let dylibPath: String?
    public let log: String
    public let error: String?
    /// 是否为构建日志里还没有的新增文件（客户端需全局导出其符号，供之后的注入引用）
    public var isNewFile: Bool = false
    public var succeeded: Bool { dylibPath != nil }
}

public struct Platform {
    public let name: String          // iphonesimulator / iphoneos / macosx
    public let sdkPath: String
    public let arch: String          // 客户端架构，用于挑选 -target 架构一致的编译命令
    public let isSimulator: Bool
    public let isDevice: Bool

    public init(name: String, sdkPath: String, arch: String, isSimulator: Bool, isDevice: Bool) {
        self.name = name
        self.sdkPath = sdkPath
        self.arch = arch
        self.isSimulator = isSimulator
        self.isDevice = isDevice
    }
}

public final class Recompiler {

    private let outputDirectory: String
    /// 工具链目录。首次使用时才查询：Engine 在主线程创建 Recompiler，
    /// xcrun 首次运行可能要好几秒（未接受 Xcode 许可时甚至一直不返回），不能放在初始化里卡住界面
    private lazy var toolchainBin: String = {
        let result = Shell.run("/usr/bin/xcrun", ["--find", "swiftc"], timeout: 60)
        let swiftc = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if swiftc.isEmpty {
            Diagnostics.shared.log("工具链", "xcrun --find swiftc 失败，退回 /usr/bin：\(result.stderr)", level: .error)
        }
        return swiftc.isEmpty ? "/usr/bin" : (swiftc as NSString).deletingLastPathComponent
    }()
    private var counter: Int = 0
    /// 会话标识：保证引擎重启后 dylib 文件名也不重复（dlopen 对同路径会直接返回旧镜像）
    private let sessionID: String
    /// 本次会话中新增、但还不在构建日志文件列表里的 Swift 文件，键为 "模块名|平台"。
    /// 之后重编同模块的其他文件时要把它们一并作为输入，否则引用不到新文件里声明的类型
    private var addedSwiftSources: [String: Set<String>] = [:]

    public init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        self.sessionID = String(Int(Date().timeIntervalSince1970) % 1_000_000)
    }

    /// 重编单个源文件，返回签名完毕的 dylib 路径
    public func recompile(sourceFile: String,
                          commands: ParsedCommands,
                          platform: Platform,
                          codesignIdentity: String?) -> RecompileResult {
        counter += 1
        let stem = "nc_\(sessionID)_\(counter)"
        let objectPath = "\(outputDirectory)/\(stem).o"
        let dylibPath = "\(outputDirectory)/\(stem).dylib"

        let compiled: (error: String?, log: String, target: String?)
        var isNewFile = false
        if sourceFile.hasSuffix(".swift") {
            compiled = compileSwift(sourceFile: sourceFile,
                                    modules: commands.swiftModules(for: platform.name, arch: platform.arch),
                                    objectPath: objectPath,
                                    stem: stem,
                                    isNewFile: &isNewFile)
        } else {
            var command = commands.clangCommand(for: sourceFile, platform: platform.name, arch: platform.arch)
            if command == nil,
               let template = commands.clangTemplate(for: sourceFile, platform: platform.name, arch: platform.arch) {
                // 新增文件：借用目录最接近的已有文件的编译命令
                command = clangCommand(from: template.command, templateSource: template.source, newSource: sourceFile)
                isNewFile = true
            }
            compiled = compileClang(sourceFile: sourceFile, command: command, objectPath: objectPath)
        }
        if let error = compiled.error {
            return RecompileResult(dylibPath: nil, log: compiled.log, error: error)
        }

        let linkResult = link(objectPath: objectPath, dylibPath: dylibPath, platform: platform, target: compiled.target)
        guard linkResult.result.succeeded else {
            Diagnostics.shared.failure(stage: "链接", file: sourceFile, summary: "链接失败",
                                       command: ["\(toolchainBin)/clang"] + linkResult.arguments,
                                       workingDirectory: outputDirectory, output: linkResult.result.stdout + linkResult.result.stderr)
            return RecompileResult(dylibPath: nil, log: compiled.log + "\n" + linkResult.result.stderr,
                                   error: "链接失败：\(linkResult.result.stderr)")
        }
        if let signError = codesign(dylibPath: dylibPath, platform: platform, identity: codesignIdentity) {
            Diagnostics.shared.failure(stage: "签名", file: sourceFile, summary: signError)
            return RecompileResult(dylibPath: nil, log: compiled.log, error: signError)
        }
        return RecompileResult(dylibPath: dylibPath, log: compiled.log, error: nil, isNewFile: isNewFile)
    }

    // MARK: - Swift

    private func compileSwift(sourceFile: String,
                              modules: [RawCompileCommand],
                              objectPath: String,
                              stem: String,
                              isNewFile: inout Bool) -> (error: String?, log: String, target: String?) {
        guard let match = swiftModule(for: sourceFile, in: modules) else {
            let message = "未在构建日志中找到包含该文件的 Swift 模块命令（请先为该平台完整构建一次）"
            Diagnostics.shared.failure(stage: "查找命令", file: sourceFile,
                                       summary: "\(message)；当前平台可用的 Swift 模块：\(modules.compactMap { $0.moduleName }.joined(separator: ", "))")
            return (message, "", nil)
        }
        let module = match.module
        isNewFile = !match.isMember
        let moduleKey = "\(module.moduleName ?? "?")|\(module.platform)"
        // 1. 清洗 driver 参数，去掉增量 / 整模块 / 产物输出相关项
        var cleaned = cleanedSwiftDriverTokens(module.tokens)
        // 新增文件（含本次与此前新增的）补进模块的输入文件列表
        var extras = addedSwiftSources[moduleKey] ?? []
        if isNewFile {
            extras.insert(sourceFile)
        }
        let existingSources = match.sources
        let missing = extras.filter { path in
            FileManager.default.fileExists(atPath: path)
                && !existingSources.contains(path)
                && !existingSources.contains(where: { ParsedCommands.canonicalPath($0) == ParsedCommands.canonicalPath(path) })
        }
        if !missing.isEmpty {
            cleaned = appendingSwiftSources(missing.sorted(), to: cleaned, stem: stem)
        }
        // 2. 用 -### 展开 frontend 命令
        var expandArgs = Array(cleaned.dropFirst())
        expandArgs.append("-###")
        let expand = Shell.run(cleaned[0], expandArgs, workingDirectory: module.workingDirectory)
        guard expand.succeeded else {
            Diagnostics.shared.failure(stage: "展开命令", file: sourceFile, summary: "无法展开 Swift 编译命令",
                                       command: [cleaned[0]] + expandArgs, workingDirectory: module.workingDirectory,
                                       output: expand.stdout + expand.stderr)
            return ("无法展开 Swift 编译命令：\(expand.stderr)", expand.stdout + expand.stderr, nil)
        }
        // 3. 找到以目标文件为 -primary-file 的那条 frontend 命令
        guard let frontendLine = frontendLine(for: sourceFile, in: expand.stdout) else {
            Diagnostics.shared.failure(stage: "展开命令", file: sourceFile, summary: "展开结果中未找到该文件的 frontend 命令",
                                       command: [cleaned[0]] + expandArgs, workingDirectory: module.workingDirectory,
                                       output: expand.stdout)
            return ("展开结果中未找到该文件的 frontend 命令", expand.stdout, nil)
        }
        var tokens = rewriteFrontendOutput(CommandTokenizer.tokenize(frontendLine), objectPath: objectPath)
        tokens = replaceMissingBridgingPCH(tokens, driverTokens: module.tokens)
        tokens.append(contentsOf: ["-D", "INJECTING"])
        let compile = Shell.run(tokens[0], Array(tokens.dropFirst()), workingDirectory: module.workingDirectory)
        if !compile.succeeded || !FileManager.default.fileExists(atPath: objectPath) {
            let message = extractCompileError(compile.stderr + compile.stdout) ?? "Swift 编译失败"
            Diagnostics.shared.failure(stage: "编译", file: sourceFile, summary: message, command: tokens,
                                       workingDirectory: module.workingDirectory, output: compile.stdout + compile.stderr)
            return (message, compile.stdout + compile.stderr, nil)
        }
        // 编译通过才登记新文件，避免它的语法错误连累同模块其他文件的重编
        if isNewFile {
            addedSwiftSources[moduleKey, default: []].insert(sourceFile)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)", module.target)
    }

    /// 找到包含该源文件的模块命令。
    /// 新增文件不在任何模块的文件列表中：选源文件目录与它最接近的模块，isMember 为 false
    private func swiftModule(for sourceFile: String,
                             in modules: [RawCompileCommand]) -> (module: RawCompileCommand, sources: Set<String>, isMember: Bool)? {
        let canonicalSource = ParsedCommands.canonicalPath(sourceFile)
        var best: (module: RawCompileCommand, sources: Set<String>, depth: Int)? = nil
        for module in modules {
            let sources = ParsedCommands.swiftSources(of: module)
            if sources.contains(sourceFile) || sources.contains(where: { ParsedCommands.canonicalPath($0) == canonicalSource }) {
                return (module, sources, true)
            }
            let depth = sources.map { ParsedCommands.commonDirectoryDepth(ParsedCommands.canonicalPath($0), canonicalSource) }.max() ?? 0
            if best == nil || depth > best!.depth {
                best = (module, sources, depth)
            }
        }
        guard let best else {
            return nil
        }
        return (best.module, best.sources, false)
    }

    /// 把额外的 Swift 源文件加入 driver 命令：有 @filelist 时写一份追加了新文件的副本，否则直接追加到参数末尾
    private func appendingSwiftSources(_ files: [String], to tokens: [String], stem: String) -> [String] {
        var result = tokens
        if let index = result.firstIndex(where: { $0.hasPrefix("@") && $0.hasSuffix(".SwiftFileList") })
            ?? result.firstIndex(where: { $0.hasPrefix("@") }) {
            let listPath = String(result[index].dropFirst())
            if let content = try? String(contentsOfFile: listPath, encoding: .utf8) {
                var lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lines.append(contentsOf: files)
                let newList = "\(outputDirectory)/\(stem).SwiftFileList"
                if (try? (lines.joined(separator: "\n") + "\n").write(toFile: newList, atomically: true, encoding: .utf8)) != nil {
                    result[index] = "@" + newList
                    return result
                }
            }
        }
        result.append(contentsOf: files)
        return result
    }

    /// 去掉会干扰单文件重编的 driver 参数
    private func cleanedSwiftDriverTokens(_ tokens: [String]) -> [String] {
        // 注意：-serialize-diagnostics 在 driver 层是不带值的布尔标志
        let dropFlags: Set<String> = [
            "-incremental", "-enable-batch-mode", "-experimental-emit-module-separately",
            "-emit-module", "-emit-dependencies", "-emit-objc-header", "-emit-const-values",
            "-emit-localized-strings", "-save-temps", "-whole-module-optimization", "-wmo",
            "-validate-clang-modules-once", "-serialize-diagnostics",
        ]
        let dropFlagsWithValue: Set<String> = [
            "-output-file-map", "-emit-module-path", "-emit-objc-header-path",
            "-emit-localized-strings-path", "-emit-module-source-info-path",
            "-index-store-path", "-const-gather-protocols-list",
            "-dependency-scan-serialize-diagnostics-path", "-clang-build-session-file",
        ]
        var result: [String] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if dropFlags.contains(token) {
                i += 1
                continue
            }
            if dropFlagsWithValue.contains(token) {
                i += 2
                continue
            }
            if token.hasPrefix("-j") {
                i += 1
                continue
            }
            // -Xcc -ivfsstatcache -Xcc <path>：缓存文件可能已失效
            if token == "-Xcc", i + 1 < tokens.count, tokens[i + 1] == "-ivfsstatcache" {
                i += 4
                continue
            }
            result.append(token)
            i += 1
        }
        return result
    }

    /// 从 -### 输出中找到目标文件对应的 frontend 行
    private func frontendLine(for sourceFile: String, in stdout: String) -> String? {
        let canonicalSource = ParsedCommands.canonicalPath(sourceFile)
        for line in stdout.components(separatedBy: "\n") {
            guard line.contains("-frontend"), line.contains("-primary-file") else {
                continue
            }
            let tokens = CommandTokenizer.tokenize(line)
            if let idx = tokens.firstIndex(of: "-primary-file"), idx + 1 < tokens.count,
               tokens[idx + 1] == sourceFile || ParsedCommands.canonicalPath(tokens[idx + 1]) == canonicalSource {
                return line
            }
        }
        return nil
    }

    /// 把 frontend 命令的输出改到我们的临时 .o，并移除会干扰的输出项
    private func rewriteFrontendOutput(_ tokens: [String], objectPath: String) -> [String] {
        var result: [String] = []
        var i = 0
        var replacedOutput = false
        let dropWithValue: Set<String> = [
            "-serialize-diagnostics-path", "-emit-reference-dependencies-path",
            "-emit-dependencies-path", "-emit-const-values-path",
            "-index-unit-output-path", "-index-store-path",
            "-supplementary-output-file-map",
            // Xcode 16+ 显式模块：依赖会被清理的预编译 .pcm，改回隐式模块构建
            "-explicit-swift-module-map-file", "-explicit-swift-module-map",
        ]
        let dropFlags: Set<String> = [
            "-frontend-parseable-output", "-disable-implicit-swift-modules",
        ]
        let dropXcc: Set<String> = ["-fno-implicit-modules", "-fno-implicit-module-maps"]
        while i < tokens.count {
            let token = tokens[i]
            if token == "-o", i + 1 < tokens.count {
                result.append("-o")
                result.append(objectPath)
                replacedOutput = true
                i += 2
                continue
            }
            if dropWithValue.contains(token) {
                i += 2
                continue
            }
            if dropFlags.contains(token) {
                i += 1
                continue
            }
            if token == "-Xcc", i + 1 < tokens.count, dropXcc.contains(tokens[i + 1]) {
                i += 2
                continue
            }
            result.append(token)
            i += 1
        }
        if !replacedOutput {
            result.append(contentsOf: ["-o", objectPath])
        }
        return result
    }

    /// `-###` 会把桥接头规划为预编译 .pch，放在 driver 退出即删除的临时目录。
    /// frontend 命令引用的 .pch 不存在时，换回 driver 命令里的原始桥接头 .h，由 frontend 直接解析
    private func replaceMissingBridgingPCH(_ tokens: [String], driverTokens: [String]) -> [String] {
        guard let idx = tokens.firstIndex(of: "-import-objc-header"), idx + 1 < tokens.count else {
            return tokens
        }
        let header = tokens[idx + 1]
        guard header.hasSuffix(".pch"), !FileManager.default.fileExists(atPath: header) else {
            return tokens
        }
        guard let original = BuildLog.valueForFlag("-import-objc-header", in: driverTokens) else {
            return tokens
        }
        var result = tokens
        result[idx + 1] = original
        return result
    }

    // MARK: - ObjC / C / C++

    /// 由模板文件的 clang 命令生成新文件的命令：替换 -c 后的源文件，语言不同时改写 -x 并去掉语言标准参数
    private func clangCommand(from template: RawCompileCommand, templateSource: String, newSource: String) -> RawCompileCommand {
        let languageChanged = ParsedCommands.clangLanguage(forPath: templateSource) != ParsedCommands.clangLanguage(forPath: newSource)
        var tokens: [String] = []
        var i = 0
        while i < template.tokens.count {
            let token = template.tokens[i]
            if token == "-c", i + 1 < template.tokens.count {
                tokens.append(contentsOf: ["-c", newSource])
                i += 2
                continue
            }
            if token == "-x", i + 1 < template.tokens.count {
                tokens.append(contentsOf: ["-x", ParsedCommands.clangLanguage(forPath: newSource)])
                i += 2
                continue
            }
            if languageChanged, token.hasPrefix("-std=") {
                i += 1
                continue
            }
            tokens.append(token)
            i += 1
        }
        return RawCompileCommand(kind: .clangFile, tokens: tokens, workingDirectory: template.workingDirectory,
                                 moduleName: template.moduleName, platform: template.platform, target: template.target)
    }

    private func compileClang(sourceFile: String,
                              command: RawCompileCommand?,
                              objectPath: String) -> (error: String?, log: String, target: String?) {
        guard let command else {
            let message = "未在构建日志中找到该文件的 clang 命令（请先为该平台完整构建一次）"
            Diagnostics.shared.failure(stage: "查找命令", file: sourceFile, summary: message)
            return (message, "", nil)
        }
        var tokens: [String] = []
        var i = 0
        let dropWithValue: Set<String> = [
            "-index-store-path", "--serialize-diagnostics", "-MF", "-MT", "-MJ",
            "-index-unit-output-path", "-ivfsstatcache",
        ]
        let dropFlags: Set<String> = [
            "-MMD", "-MD", "-fmodules-validate-once-per-build-session",
        ]
        while i < command.tokens.count {
            let token = command.tokens[i]
            if token == "-o", i + 1 < command.tokens.count {
                tokens.append("-o")
                tokens.append(objectPath)
                i += 2
                continue
            }
            if dropWithValue.contains(token) {
                i += 2
                continue
            }
            if dropFlags.contains(token) {
                i += 1
                continue
            }
            // 指向会被清理的构建会话文件，去掉以免找不到
            if token.hasPrefix("-fbuild-session-file=") {
                i += 1
                continue
            }
            tokens.append(token)
            i += 1
        }
        // 跳过 PCH 校验，避免因模块缓存时间戳导致失败
        tokens.append(contentsOf: ["-Xclang", "-fno-validate-pch"])
        let compile = Shell.run(tokens[0], Array(tokens.dropFirst()), workingDirectory: command.workingDirectory)
        if !compile.succeeded || !FileManager.default.fileExists(atPath: objectPath) {
            let message = extractCompileError(compile.stderr + compile.stdout) ?? "编译失败"
            Diagnostics.shared.failure(stage: "编译", file: sourceFile, summary: message, command: tokens,
                                       workingDirectory: command.workingDirectory, output: compile.stdout + compile.stderr)
            return (message, compile.stdout + compile.stderr, nil)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)", command.target)
    }

    // MARK: - 链接与签名

    private func link(objectPath: String, dylibPath: String, platform: Platform, target: String?) -> (result: ShellResult, arguments: [String]) {
        let swiftLibDir = "\(toolchainBin)/../lib/swift/\(platform.name)"
        var args: [String] = []
        // 优先沿用编译时的 -target，保证平台与最低系统版本一致
        if let target {
            args.append(contentsOf: ["-target", target])
        } else {
            args.append(contentsOf: ["-arch", platform.arch])
        }
        args.append(contentsOf: [
            "-isysroot", platform.sdkPath,
            "-dynamiclib",
            "-undefined", "dynamic_lookup",
            "-Xlinker", "-interposable",
            "-fobjc-arc",
            "-L", swiftLibDir,
            "-install_name", "@rpath/\((dylibPath as NSString).lastPathComponent)",
        ])
        // 仅当目标文件开启了代码覆盖率时才链接 profile 运行时
        if needsProfileRuntime(objectPath: objectPath) {
            args.append("-fprofile-instr-generate")
        }
        // C++ 代码需要 libc++
        args.append("-lc++")
        args.append(contentsOf: [objectPath, "-o", dylibPath])
        return (Shell.run("\(toolchainBin)/clang", args, workingDirectory: outputDirectory), args)
    }

    private func needsProfileRuntime(objectPath: String) -> Bool {
        let result = Shell.run("\(toolchainBin)/nm", ["-u", objectPath])
        return result.stdout.contains("___llvm_profile_runtime")
    }

    private func codesign(dylibPath: String, platform: Platform, identity: String?) -> String? {
        // 模拟器：链接器已自动 ad-hoc 签名
        if platform.isSimulator {
            return nil
        }
        let signIdentity: String
        if platform.isDevice {
            guard let identity, !identity.isEmpty else {
                return "真机注入需要开发者签名身份，但未能从构建日志中获取。请先在 Xcode 完成一次真机构建。"
            }
            signIdentity = identity
        } else {
            // macOS：默认 ad-hoc。若 App 开了 Hardened Runtime + 库校验，需在 Debug 关闭库校验
            signIdentity = "-"
        }
        let result = Shell.run("/usr/bin/codesign", ["--force", "--sign", signIdentity, "--timestamp=none", dylibPath])
        return result.succeeded ? nil : "签名失败：\(result.stderr)"
    }

    // MARK: - 错误提取

    private func extractCompileError(_ output: String) -> String? {
        let lines = output.components(separatedBy: "\n").filter { $0.contains(": error:") }
        if lines.isEmpty {
            return nil
        }
        return lines.prefix(10).joined(separator: "\n")
    }
}
