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
    public var succeeded: Bool { dylibPath != nil }
}

public struct Platform {
    public let name: String          // iphonesimulator / iphoneos / macosx
    public let sdkPath: String
    public let arch: String
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
    private let toolchainBin: String
    private var counter: Int = 0
    /// 会话标识：保证引擎重启后 dylib 文件名也不重复（dlopen 对同路径会直接返回旧镜像）
    private let sessionID: String

    public init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let swiftc = Shell.run("/usr/bin/xcrun", ["--find", "swiftc"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.toolchainBin = swiftc.isEmpty ? "/usr/bin" : (swiftc as NSString).deletingLastPathComponent
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
        if sourceFile.hasSuffix(".swift") {
            compiled = compileSwift(sourceFile: sourceFile,
                                    modules: commands.swiftModules(for: platform.name),
                                    objectPath: objectPath)
        } else {
            compiled = compileClang(sourceFile: sourceFile,
                                    command: commands.clangCommand(for: sourceFile, platform: platform.name),
                                    objectPath: objectPath)
        }
        if let error = compiled.error {
            return RecompileResult(dylibPath: nil, log: compiled.log, error: error)
        }

        let linkResult = link(objectPath: objectPath, dylibPath: dylibPath, platform: platform, target: compiled.target)
        guard linkResult.succeeded else {
            return RecompileResult(dylibPath: nil, log: compiled.log + "\n" + linkResult.stderr,
                                   error: "链接失败：\(linkResult.stderr)")
        }
        if let signError = codesign(dylibPath: dylibPath, platform: platform, identity: codesignIdentity) {
            return RecompileResult(dylibPath: nil, log: compiled.log, error: signError)
        }
        return RecompileResult(dylibPath: dylibPath, log: compiled.log, error: nil)
    }

    // MARK: - Swift

    private func compileSwift(sourceFile: String,
                              modules: [RawCompileCommand],
                              objectPath: String) -> (error: String?, log: String, target: String?) {
        guard let module = swiftModule(for: sourceFile, in: modules) else {
            return ("未在构建日志中找到包含该文件的 Swift 模块命令（请先为该平台完整构建一次）", "", nil)
        }
        // 1. 清洗 driver 参数，去掉增量 / 整模块 / 产物输出相关项
        let cleaned = cleanedSwiftDriverTokens(module.tokens)
        // 2. 用 -### 展开 frontend 命令
        var expandArgs = Array(cleaned.dropFirst())
        expandArgs.append("-###")
        let expand = Shell.run(cleaned[0], expandArgs, workingDirectory: module.workingDirectory)
        guard expand.succeeded else {
            return ("无法展开 Swift 编译命令：\(expand.stderr)", expand.stdout + expand.stderr, nil)
        }
        // 3. 找到以目标文件为 -primary-file 的那条 frontend 命令
        guard let frontendLine = frontendLine(for: sourceFile, in: expand.stdout) else {
            return ("展开结果中未找到该文件的 frontend 命令", expand.stdout, nil)
        }
        var tokens = rewriteFrontendOutput(CommandTokenizer.tokenize(frontendLine), objectPath: objectPath)
        tokens.append(contentsOf: ["-D", "INJECTING"])
        let compile = Shell.run(tokens[0], Array(tokens.dropFirst()), workingDirectory: module.workingDirectory)
        if !compile.succeeded || !FileManager.default.fileExists(atPath: objectPath) {
            return (extractCompileError(compile.stderr + compile.stdout) ?? "Swift 编译失败",
                    compile.stdout + compile.stderr, nil)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)", module.target)
    }

    /// 找到包含该源文件的模块命令
    private func swiftModule(for sourceFile: String, in modules: [RawCompileCommand]) -> RawCompileCommand? {
        for module in modules {
            if swiftSources(of: module).contains(sourceFile) {
                return module
            }
        }
        // 新增文件不在旧的文件列表中：模块只有一个时直接用它
        return modules.count == 1 ? modules.first : nil
    }

    /// 取模块命令涉及的所有 swift 源文件（含 @filelist）
    private func swiftSources(of module: RawCompileCommand) -> Set<String> {
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
        for line in stdout.components(separatedBy: "\n") {
            guard line.contains("-frontend"), line.contains("-primary-file") else {
                continue
            }
            let tokens = CommandTokenizer.tokenize(line)
            if let idx = tokens.firstIndex(of: "-primary-file"), idx + 1 < tokens.count,
               tokens[idx + 1] == sourceFile {
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

    // MARK: - ObjC / C / C++

    private func compileClang(sourceFile: String,
                              command: RawCompileCommand?,
                              objectPath: String) -> (error: String?, log: String, target: String?) {
        guard let command else {
            return ("未在构建日志中找到该文件的 clang 命令（请先为该平台完整构建一次）", "", nil)
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
            return (extractCompileError(compile.stderr + compile.stdout) ?? "编译失败",
                    compile.stdout + compile.stderr, nil)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)", command.target)
    }

    // MARK: - 链接与签名

    private func link(objectPath: String, dylibPath: String, platform: Platform, target: String?) -> ShellResult {
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
        return Shell.run("\(toolchainBin)/clang", args, workingDirectory: outputDirectory)
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
