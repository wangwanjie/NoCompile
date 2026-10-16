//
//  Diagnostics.swift
//  诊断日志：把各环节（监听、解析构建日志、编译、链接、签名、发送、注入、连接）的细节与错误
//  写入 ~/Library/Logs/NoCompile，并能打包成 zip，方便用户导出反馈问题。
//
//  目录结构：
//    NoCompile.log            控制台日志（本次启动）
//    NoCompile.previous.log   上一次启动的控制台日志
//    Diagnostics.log          诊断明细（跨启动保留，超过上限自动轮转为 Diagnostics.1.log）
//    Failures/                每次编译 / 链接 / 签名失败的完整命令与输出（保留最近 50 份）
//    Hangs/                   主线程卡顿时采集的调用栈（Mac App 内的看门狗写入）
//
//  所有写入都在内部串行队列上异步完成，任何线程都可以调用，不会阻塞调用方。
//

import Foundation

/// 追加写入的日志文件：持有文件句柄，在后台串行队列写入，避免每行都开关文件
public final class LogFileWriter {

    public let url: URL
    private let queue: DispatchQueue
    private var handle: FileHandle?
    private let maxBytes: UInt64
    private var writtenBytes: UInt64 = 0

    /// - Parameters:
    ///   - truncate: 打开时清空原内容
    ///   - maxBytes: 超过后轮转为 "<文件名>.1.<扩展名>"，0 表示不限制
    public init(url: URL, truncate: Bool, maxBytes: UInt64 = 0) {
        self.url = url
        self.maxBytes = maxBytes
        self.queue = DispatchQueue(label: "com.nocompile.logfile.\(url.lastPathComponent)", qos: .utility)
        queue.async { [weak self] in
            self?.open(truncate: truncate)
        }
    }

    deinit {
        try? handle?.close()
    }

    private func open(truncate: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if truncate || !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        writtenBytes = (try? handle?.seekToEnd()) ?? 0
    }

    public func write(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.maxBytes > 0, self.writtenBytes + UInt64(data.count) > self.maxBytes {
                self.rotate()
            }
            try? self.handle?.write(contentsOf: data)
            self.writtenBytes += UInt64(data.count)
        }
    }

    /// 等待已提交的写入落盘（导出诊断包前调用）
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let rotated = url.deletingLastPathComponent().appendingPathComponent("\(base).1.\(ext)")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        open(truncate: true)
    }
}

public final class Diagnostics {

    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        /// 与引擎日志等级（0 信息 / 1 成功 / 2 警告 / 3 错误）对应
        public init(engineLevel: Int) {
            switch engineLevel {
            case 3: self = .error
            case 2: self = .warning
            default: self = .info
            }
        }
    }

    public static let shared = Diagnostics()

    /// ~/Library/Logs/NoCompile
    public let directory: URL
    public var failuresDirectory: URL { directory.appendingPathComponent("Failures", isDirectory: true) }
    public var hangsDirectory: URL { directory.appendingPathComponent("Hangs", isDirectory: true) }

    private let writer: LogFileWriter
    private let failureQueue = DispatchQueue(label: "com.nocompile.diagnostics.failures", qos: .utility)
    private let maxFailureFiles = 50

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private let formatterLock = NSLock()

    private init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoCompile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = LogFileWriter(url: directory.appendingPathComponent("Diagnostics.log"),
                               truncate: false, maxBytes: 20 * 1024 * 1024)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? NCProtocol.clientVersion
        let build = info?["CFBundleVersion"] as? String ?? "-"
        writer.write("\n========== 启动 \(ProcessInfo.processInfo.processName) \(version)(\(build)) pid=\(getpid()) ==========\n")
    }

    public func timestamp(_ date: Date = Date()) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return timestampFormatter.string(from: date)
    }

    /// 记录一条诊断日志。stage 为环节名，如 "解析日志"、"编译"、"连接"
    public func log(_ stage: String, _ message: String, level: Level = .info) {
        writer.write("[\(timestamp())] [\(level.rawValue)] [\(stage)] \(message)\n")
    }

    /// 记录一次失败的完整现场：命令行、工作目录、输出。同时在 Diagnostics.log 里留一行索引
    public func failure(stage: String, file: String, summary: String,
                        command: [String]? = nil, workingDirectory: String? = nil, output: String? = nil) {
        let date = Date()
        let name = (file as NSString).lastPathComponent
        log(stage, "失败：\(name)：\(summary.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(500))", level: .error)
        failureQueue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: failuresDirectory, withIntermediateDirectories: true)
            let stamp = timestamp(date).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
            let safeName = name.replacingOccurrences(of: "/", with: "_")
            let url = failuresDirectory.appendingPathComponent("\(stamp)_\(stage)_\(safeName).txt")
            var text = "时间：\(timestamp(date))\n环节：\(stage)\n文件：\(file)\n摘要：\n\(summary)\n"
            if let workingDirectory {
                text += "\n工作目录：\(workingDirectory)\n"
            }
            if let command {
                text += "\n命令：\n\(command.map(Self.shellQuoted).joined(separator: " "))\n"
            }
            if let output, !output.isEmpty {
                // 输出可能极长（成百上千条报错），截取首尾
                let limit = 200_000
                let body = output.count > limit
                    ? String(output.prefix(limit / 2)) + "\n…（中间省略 \(output.count - limit) 个字符）…\n" + String(output.suffix(limit / 2))
                    : output
                text += "\n输出：\n\(body)\n"
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            pruneFailures()
        }
    }

    private func pruneFailures() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: failuresDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        // 文件名以时间戳开头，按名字排序即按时间排序
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if sorted.count > maxFailureFiles {
            for url in sorted.prefix(sorted.count - maxFailureFiles) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 让命令可直接复制到终端复现
    static func shellQuoted(_ argument: String) -> String {
        if argument.isEmpty {
            return "''"
        }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func flush() {
        writer.flush()
        failureQueue.sync {}
    }

    // MARK: - 导出

    /// 本机环境信息：系统、Xcode、架构
    public static func environmentReport() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        lines.append("NoCompile：\(info?["CFBundleShortVersionString"] as? String ?? "-")（\(info?["CFBundleVersion"] as? String ?? "-")），客户端协议版本 \(NCProtocol.clientVersion)")
        lines.append("macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        lines.append("架构：\(machine)")
        let xcodeSelect = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        lines.append("xcode-select：\(xcodeSelect.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        let xcodebuild = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 20)
        lines.append("Xcode：\(xcodebuild.stdout.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))")
        let swift = Shell.run("/usr/bin/xcrun", ["swift", "--version"], timeout: 20)
        lines.append("Swift：\((swift.stdout + swift.stderr).components(separatedBy: "\n").first ?? "")")
        return lines.joined(separator: "\n")
    }

    /// 打包诊断信息为 zip：日志目录的全部内容 + 调用方提供的概要（工程、连接、偏好、最近注入等）。
    /// 耗时操作（会执行 xcodebuild -version、ditto），请在后台线程调用
    public func exportBundle(to zipURL: URL, summary: String) throws {
        flush()
        let fm = FileManager.default
        let stamp = timestamp().replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let staging = fm.temporaryDirectory.appendingPathComponent("NoCompile-Diagnostics-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: staging)
        }
        // 拷贝日志目录（逐项拷贝，单个文件失败不影响整体）
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
            }
        }
        let report = "生成时间：\(timestamp())\n\n[环境]\n\(Self.environmentReport())\n\n\(summary)\n"
        try report.write(to: staging.appendingPathComponent("Summary.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: zipURL)
        let result = Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", staging.path, zipURL.path],
                               timeout: 120)
        guard result.succeeded else {
            throw NSError(domain: "NoCompile", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "打包失败：\(result.stderr)"])
        }
        log("诊断", "已导出诊断包：\(zipURL.path)")
    }
}
