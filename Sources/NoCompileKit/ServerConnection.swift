//
//  ServerConnection.swift
//  Mac 端对单个客户端连接的封装
//

import Foundation

public protocol ServerConnectionDelegate: AnyObject {
    func connection(_ connection: ServerConnection, didReceive message: NCMessage)
    func connectionDidClose(_ connection: ServerConnection)
}

public final class ServerConnection {

    public weak var delegate: ServerConnectionDelegate?
    /// 握手信息（hello 内容）。读循环线程写入、引擎队列读取，需加锁
    public var clientInfo: [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _clientInfo
    }
    private var _clientInfo: [String: Any] = [:]
    /// 与 Mac 端不兼容的原因（版本不一致等）；非空时不向它推送注入
    public var compatibilityIssue: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _compatibilityIssue
        }
        set {
            stateLock.lock()
            _compatibilityIssue = newValue
            stateLock.unlock()
        }
    }
    private var _compatibilityIssue: String?
    /// 客户端上报的版本，旧版客户端没有该字段
    public var clientVersion: String? { clientInfo["clientVersion"] as? String }
    private let stateLock = NSLock()
    public var platformName: String { clientInfo["platform"] as? String ?? "" }
    public var machine: String { clientInfo["machine"] as? String ?? "arm64" }
    public var isLocalFileSystem: Bool {
        // 模拟器与本机 Mac 共享文件系统，可直接用路径
        let p = platformName
        return p == "simulator" || p == "macosx"
    }
    /// 关闭时的额外回调（供 DeviceBridge 释放设备占用）
    public var onClose: (() -> Void)?

    /// 日志用短名：App 可执行文件名
    public var shortName: String {
        let executable = clientInfo["executable"] as? String ?? ""
        let name = (executable as NSString).lastPathComponent
        return name.isEmpty ? "App" : name
    }

    /// 连接的稳定标识
    public let id = UUID().uuidString

    /// 平台的中文名
    public var platformTitle: String {
        switch platformName {
        case "simulator": return "模拟器"
        case "device": return "真机"
        case "macosx": return "macOS"
        default: return platformName
        }
    }

    /// 展示用名称：App 名 + 平台
    public var displayName: String {
        let bundleID = clientInfo["bundleID"] as? String ?? ""
        return "\(shortName)（\(platformTitle)\(bundleID.isEmpty ? "" : "，\(bundleID)")）"
    }

    private let fd: Int32
    private let queue: DispatchQueue        // 读循环（长期阻塞）
    private let writeQueue: DispatchQueue   // 写（独立队列，避免被读循环饿死）
    private var buffer = Data()
    /// 读循环、写队列、引擎队列都会访问，用 stateLock 保护
    private var _running = false
    private var running: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running
    }

    public init(fd: Int32) {
        self.fd = fd
        self.queue = DispatchQueue(label: "com.nocompile.server.conn.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "com.nocompile.server.conn.write.\(fd)")
    }

    public func start() {
        stateLock.lock()
        _running = true
        stateLock.unlock()
        // 写阻塞（对端暂停在调试器、不再读取）时最多等 10 秒，避免写队列永久卡住
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    public func close() {
        // 读循环、引擎可能同时调用，只允许关闭一次
        stateLock.lock()
        guard _running else {
            stateLock.unlock()
            return
        }
        _running = false
        let callback = onClose
        onClose = nil
        stateLock.unlock()
        // shutdown 先唤醒阻塞在 read 上的读循环，再关闭描述符
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        delegate?.connectionDidClose(self)
        callback?()
    }

    func updateClientInfo(_ info: [String: Any]) {
        stateLock.lock()
        _clientInfo = info
        stateLock.unlock()
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while running {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                break
            }
            buffer.append(contentsOf: chunk[0 ..< n])
            drainBuffer()
        }
        close()
    }

    private func drainBuffer() {
        while true {
            do {
                guard let (message, consumed) = try NCFrameCodec.decode(from: buffer) else {
                    return
                }
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
                delegate?.connection(self, didReceive: message)
            } catch {
                // 协议错乱（多半是版本差异过大的客户端），断开
                Diagnostics.shared.log("连接", "\(displayName) 协议解析失败（\(error)），断开连接", level: .error)
                close()
                return
            }
        }
    }

    public func send(_ message: NCMessage) {
        let frame = NCFrameCodec.encode(message)
        writeQueue.async { [weak self] in
            guard let self, self.running else { return }
            frame.withUnsafeBytes { raw in
                var sent = 0
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while sent < frame.count {
                    let n = write(self.fd, base + sent, frame.count - sent)
                    if n <= 0 {
                        // 写超时或对端已断开：关闭连接，避免后续消息继续堆积
                        Diagnostics.shared.log("连接", "向 \(self.displayName) 发送消息失败（errno \(errno)），断开连接", level: .error)
                        self.close()
                        break
                    }
                    sent += n
                }
            }
        }
    }
}
