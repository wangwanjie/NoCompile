//
//  CommandCache.swift
//  把解析出的编译命令持久化到磁盘。
//
//  Xcode 只保留最近若干份构建日志：完整构建的日志被后续增量构建挤掉之后，
//  没被改动过的文件在剩下的日志里没有编译命令，热重载就会报"请先完整构建一次"。
//  命令缓存把每次解析的结果累积下来，日志被清理后仍然可用；
//  同时让引擎重启时不必重新解压、解析全部日志（大型工程要几秒到几十秒）。
//

import Foundation

enum CommandCache {

    /// 缓存格式版本，结构变化时递增（旧缓存直接丢弃）
    private static let schemaVersion = 2

    private struct Payload: Codable {
        var schema: Int
        /// 生成缓存时的 Xcode 开发者目录与版本号（如 "/Applications/Xcode.app/Contents/Developer|17A100"）：
        /// Xcode 原地升级后路径不变但 SDK 目录名带版本号，缓存里的命令会指向已不存在的 SDK，必须作废
        var developerDir: String
        var derivedDataPath: String
        /// 已解析的日志及其修改时间（秒），这些日志不必再解析
        var parsedLogs: [String: TimeInterval]
        var commands: ParsedCommands
    }

    struct Loaded {
        var commands: ParsedCommands
        var parsedLogs: [String: Date]
    }

    static var directory: String {
        return NSHomeDirectory() + "/Library/Caches/NoCompile/CommandCache"
    }

    private static func path(forDerivedData derivedDataPath: String) -> String {
        // 目录名 + 路径哈希，避免同名工程冲突
        let name = (derivedDataPath as NSString).lastPathComponent
        var hash: UInt64 = 5381
        for byte in derivedDataPath.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return "\(directory)/\(name)-\(String(hash, radix: 16)).json"
    }

    /// 当前 Xcode 的标识：开发者目录 + 构建版本号。GUI 进程拿不到 DEVELOPER_DIR，以 xcode-select 的结果为准
    private static let developerDir: String = {
        var directory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
        if directory.isEmpty {
            directory = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if directory.isEmpty {
            directory = "/Applications/Xcode.app/Contents/Developer"
        }
        let versionPlist = ((directory as NSString).deletingLastPathComponent as NSString).appendingPathComponent("version.plist")
        let build = NSDictionary(contentsOfFile: versionPlist)?["ProductBuildVersion"] as? String ?? ""
        return "\(directory)|\(build)"
    }()

    static func load(derivedDataPath: String) -> Loaded? {
        let file = path(forDerivedData: derivedDataPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schema == schemaVersion,
              payload.derivedDataPath == derivedDataPath,
              payload.developerDir == developerDir else {
            Diagnostics.shared.log("命令缓存", "缓存已过期或格式不符，忽略：\(file)", level: .debug)
            return nil
        }
        let logs = payload.parsedLogs.mapValues { Date(timeIntervalSince1970: $0) }
        Diagnostics.shared.log("命令缓存", "载入 \(payload.commands.swiftModules.count) 条 Swift 模块命令、"
            + "\(payload.commands.clangFiles.count) 条 clang 命令（\(file)）")
        return Loaded(commands: payload.commands, parsedLogs: logs)
    }

    static func save(derivedDataPath: String, commands: ParsedCommands, parsedLogs: [String: Date]) {
        let payload = Payload(schema: schemaVersion,
                              developerDir: developerDir,
                              derivedDataPath: derivedDataPath,
                              parsedLogs: parsedLogs.mapValues { $0.timeIntervalSince1970 },
                              commands: commands)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            // 先写临时文件再改名，进程中途退出也不会留下写了一半的缓存
            let file = path(forDerivedData: derivedDataPath)
            let temp = file + ".tmp"
            try data.write(to: URL(fileURLWithPath: temp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: file), withItemAt: URL(fileURLWithPath: temp))
        } catch {
            Diagnostics.shared.log("命令缓存", "写入失败：\(error.localizedDescription)", level: .warning)
        }
    }
}
