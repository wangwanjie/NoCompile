//
//  Shell.swift
//  子进程执行工具。全程用参数数组传递，不拼接 shell 字符串，
//  从而天然支持含空格、中文、特殊字符的路径。
//
//  所有调用都有超时：编译器卡住、或子进程派生的后台进程（如 ibtool 拉起的 ibtoold）
//  一直占着输出管道时，不能让调用方（引擎的串行队列）永远等下去。
//

import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// 是否因超时被终止
    public var timedOut: Bool = false
    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum Shell {

    /// 默认超时（秒）。单文件编译、链接、签名正常都在几秒内完成
    public static let defaultTimeout: TimeInterval = 300

    /// 执行可执行文件，等待结束并返回结果
    @discardableResult
    public static func run(_ launchPath: String,
                           _ arguments: [String],
                           workingDirectory: String? = nil,
                           environment: [String: String]? = nil,
                           timeout: TimeInterval = defaultTimeout) -> ShellResult {
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

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ShellResult(status: -1, stdout: "", stderr: "无法启动进程 \(launchPath)：\(error.localizedDescription)")
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // 超时：先礼后兵，SIGTERM 不奏效再 SIGKILL
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // 进程已退出，但它派生的后台进程可能继承了管道、迟迟不关闭：最多再等 3 秒读完剩余输出
        if group.wait(timeout: .now() + 3) == .timedOut {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
        let output = ioQueue.sync { (outData, errData) }
        var stderr = String(data: output.1, encoding: .utf8) ?? ""
        if timedOut {
            let command = ([launchPath] + arguments).joined(separator: " ")
            stderr += "\n执行超时（\(Int(timeout))s）已终止：\(command.prefix(300))"
            Diagnostics.shared.log("Shell", "执行超时（\(Int(timeout))s）：\(command)", level: .error)
        }
        return ShellResult(status: process.isRunning ? -1 : process.terminationStatus,
                           stdout: String(data: output.0, encoding: .utf8) ?? "",
                           stderr: stderr,
                           timedOut: timedOut)
    }

    /// 流式执行：逐块回调标准输出，不在内存中累积全部输出。
    /// 用于解压大型构建日志（大工程解压后可达 GB 级）。标准错误丢弃。返回是否正常退出
    @discardableResult
    public static func stream(_ launchPath: String,
                              _ arguments: [String],
                              timeout: TimeInterval = 600,
                              chunk: (UnsafeBufferPointer<UInt8>) -> Void) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Diagnostics.shared.log("Shell", "无法启动进程 \(launchPath)：\(error.localizedDescription)", level: .error)
            return false
        }
        // 看门狗：超时后终止进程，读端随之读到 EOF
        let deadline = DispatchWorkItem {
            if process.isRunning {
                Diagnostics.shared.log("Shell", "流式读取超时（\(Int(timeout))s），终止：\(launchPath) \(arguments.joined(separator: " "))", level: .error)
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        let fd = outPipe.fileHandleForReading.fileDescriptor
        let bufferSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }
        while true {
            let n = read(fd, buffer, bufferSize)
            if n <= 0 {
                break
            }
            chunk(UnsafeBufferPointer(start: buffer, count: n))
        }
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0
    }

    /// 通过 xcrun 执行 Xcode 工具链中的工具
    @discardableResult
    public static func xcrun(_ tool: String, _ arguments: [String], workingDirectory: String? = nil) -> ShellResult {
        return run("/usr/bin/xcrun", [tool] + arguments, workingDirectory: workingDirectory)
    }
}
