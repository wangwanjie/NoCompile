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
    /// 握手信息（hello 内容）
    public private(set) var clientInfo: [String: Any] = [:]
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
    private var running = false

    public init(fd: Int32) {
        self.fd = fd
        self.queue = DispatchQueue(label: "com.nocompile.server.conn.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "com.nocompile.server.conn.write.\(fd)")
    }

    public func start() {
        running = true
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    public func close() {
        guard running else { return }
        running = false
        Darwin.close(fd)
        delegate?.connectionDidClose(self)
        onClose?()
        onClose = nil
    }

    func updateClientInfo(_ info: [String: Any]) {
        clientInfo = info
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
                // 协议错乱，断开
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
                        break
                    }
                    sent += n
                }
            }
        }
    }
}
