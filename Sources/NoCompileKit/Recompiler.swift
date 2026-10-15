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

    private let buildLog: BuildLog
    private let outputDirectory: String
    private var counter: Int = 0
    private let toolchainBin: String

    public init(buildLog: BuildLog, outputDirectory: String) {
        self.buildLog = buildLog
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        // 定位工具链 bin 目录
        let result = Shell.run("/usr/bin/xcrun", ["--find", "swiftc"])
        let swiftc = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        self.toolchainBin = swiftc.isEmpty
            ? "/usr/bin"
            : (swiftc as NSString).deletingLastPathComponent
    }

    /// 重编单个源文件，返回签名完毕的 dylib 路径
    public func recompile(sourceFile: String,
                          commands: (swiftModules: [RawCompileCommand], clangFiles: [String: RawCompileCommand]),
                          platform: Platform,
                          codesignIdentity: String?) -> RecompileResult {
        counter += 1
        let objectPath = "\(outputDirectory)/nc_object_\(counter).o"
        let dylibPath = "\(outputDirectory)/nc_injection_\(counter).dylib"

        let isSwift = sourceFile.hasSuffix(".swift")
        let compileLog: String
        let compileError: String?
        if isSwift {
            (compileError, compileLog) = compileSwift(sourceFile: sourceFile,
                                                      modules: commands.swiftModules,
                                                      objectPath: objectPath)
        } else {
            (compileError, compileLog) = compileClang(sourceFile: sourceFile,
                                                      clangFiles: commands.clangFiles,
                                                      objectPath: objectPath)
        }
        if let compileError {
            return RecompileResult(dylibPath: nil, log: compileLog, error: compileError)
        }

        // 链接
        let linkResult = link(objectPath: objectPath, dylibPath: dylibPath, platform: platform)
        guard linkResult.succeeded else {
            return RecompileResult(dylibPath: nil, log: compileLog + "\n" + linkResult.stdout + linkResult.stderr,
                                   error: "链接失败：\(linkResult.stderr)")
        }

        // 签名
        if let signError = codesign(dylibPath: dylibPath, platform: platform, identity: codesignIdentity) {
            return RecompileResult(dylibPath: nil, log: compileLog, error: signError)
        }
        return RecompileResult(dylibPath: dylibPath, log: compileLog, error: nil)
    }

    // MARK: - Swift

    private func compileSwift(sourceFile: String,
                              modules: [RawCompileCommand],
                              objectPath: String) -> (error: String?, log: String) {
        guard let module = swiftModule(for: sourceFile, in: modules) else {
            return ("未在构建日志中找到包含该文件的 Swift 模块命令（该文件所属 target 是否已完整编译过？）", "")
        }
        // 1. 清洗 driver 参数，去掉增量 / 整模块 / 产物输出相关项
        let cleaned = cleanedSwiftDriverTokens(module.tokens)
        // 2. 用 -### 展开 frontend 命令
        var expandArgs = Array(cleaned.dropFirst()) // 去掉 swiftc 本身
        expandArgs.append("-###")
        let expand = Shell.run(cleaned[0], expandArgs, workingDirectory: module.workingDirectory)
        guard expand.succeeded else {
            return ("无法展开 Swift 编译命令：\(expand.stderr)", expand.stdout + expand.stderr)
        }
        // 3. 找到以目标文件为 -primary-file 的那条 frontend 命令
        guard let frontendLine = frontendLine(for: sourceFile, in: expand.stdout) else {
            return ("展开结果中未找到该文件的 frontend 命令", expand.stdout)
        }
        var tokens = CommandTokenizer.tokenize(frontendLine)
        tokens = rewriteFrontendOutput(tokens, objectPath: objectPath)
        tokens.append(contentsOf: ["-D", "DEBUG", "-D", "INJECTING"])
        let compile = Shell.run(tokens[0], Array(tokens.dropFirst()), workingDirectory: module.workingDirectory)
        if !compile.succeeded || !FileManager.default.fileExists(atPath: objectPath) {
            return (extractCompileError(compile.stderr + compile.stdout) ?? "Swift 编译失败",
                    compile.stdout + compile.stderr)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)")
    }

    /// 找到包含该源文件的模块命令
    private func swiftModule(for sourceFile: String, in modules: [RawCompileCommand]) -> RawCompileCommand? {
        if modules.count == 1 {
            return modules.first
        }
        for module in modules {
            if swiftSources(of: module).contains(sourceFile) {
                return module
            }
        }
        return nil
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
            if token.hasPrefix("-j") {   // 并发度
                i += 1
                continue
            }
            // -Xcc -ivfsstatcache <path>：缓存文件可能已失效
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
            // Xcode 16+ 显式模块：这些依赖会被清理掉的预编译 .pcm，改回隐式模块构建
            "-explicit-swift-module-map-file", "-explicit-swift-module-map",
        ]
        let dropFlags: Set<String> = [
            "-frontend-parseable-output", "-disable-implicit-swift-modules",
        ]
        // 需要连同 -Xcc 前缀一起丢弃的 clang 参数（关闭隐式模块会导致找不到 .pcm）
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
                              clangFiles: [String: RawCompileCommand],
                              objectPath: String) -> (error: String?, log: String) {
        guard let command = clangFiles[sourceFile] else {
            return ("未在构建日志中找到该文件的 clang 命令（该文件所属 target 是否已完整编译过？）", "")
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
                    compile.stdout + compile.stderr)
        }
        return (nil, "编译成功：\((sourceFile as NSString).lastPathComponent)")
    }

    // MARK: - 链接与签名

    private func link(objectPath: String, dylibPath: String, platform: Platform) -> ShellResult {
        let swiftLibDir = "\(toolchainBin)/../lib/swift/\(platform.name)"
        var args: [String] = [
            "-arch", platform.arch,
            "-isysroot", platform.sdkPath,
            "-dynamiclib",
            "-undefined", "dynamic_lookup",
            "-Xlinker", "-interposable",
            "-fobjc-arc",
            "-fprofile-instr-generate",
            "-L", swiftLibDir,
            objectPath,
            "-o", dylibPath,
        ]
        // 让 dylib 能找到 App 包里的 framework
        args.append(contentsOf: ["-L", swiftLibDir, "-rpath", swiftLibDir])
        return Shell.run("\(toolchainBin)/clang", args, workingDirectory: outputDirectory)
    }

    private func codesign(dylibPath: String, platform: Platform, identity: String?) -> String? {
        // 模拟器无需签名；macOS 与真机需要签名（真机用开发者身份）
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
            signIdentity = identity?.isEmpty == false ? identity! : "-"  // macOS 默认 ad-hoc
        }
        let result = Shell.run("/usr/bin/codesign", ["--force", "--sign", signIdentity, dylibPath])
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
