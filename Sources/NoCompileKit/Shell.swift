//
//  Shell.swift
//  子进程执行工具。全程用参数数组传递，不拼接 shell 字符串，
//  从而天然支持含空格、中文、特殊字符的路径。
//

import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum Shell {
    /// 执行可执行文件，等待结束并返回结果
    @discardableResult
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           workingDirectory: String? = nil,
                           environment: [String: String]? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environment {
            process.environment = environment
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 边读边收，避免管道缓冲区写满导致死锁
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.nocompile.shell.io")
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                ioQueue.sync { outData.append(chunk) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                ioQueue.sync { errData.append(chunk) }
            }
        }
        group.enter()
        group.enter()

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "无法启动进程 \(launchPath)：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        group.wait()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(data: outData, encoding: .utf8) ?? "",
                           stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    /// 通过 xcrun 执行 Xcode 工具链中的工具
    @discardableResult
    public static func xcrun(_ tool: String, _ arguments: [String], workingDirectory: String? = nil) -> ShellResult {
        return run("/usr/bin/xcrun", [tool] + arguments, workingDirectory: workingDirectory)
    }
}
