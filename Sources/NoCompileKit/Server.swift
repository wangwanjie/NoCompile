//
//  Server.swift
//  监听本机端口，接受模拟器 / macOS 客户端连接。
//  真机通过 usbmuxd 转发到同一端口（见 DeviceBridge）。
//

import Foundation

public protocol ServerDelegate: AnyObject {
    func server(_ server: Server, didAccept connection: ServerConnection)
}

public final class Server {

    public weak var delegate: ServerDelegate?
    private var listenFD: Int32 = -1
    private let port: UInt16
    private var running = false

    public init(port: UInt16 = NCProtocol.macPort) {
        self.port = port
    }

    @discardableResult
    public func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // 绑定所有网卡，便于真机 Wi-Fi 连接；usbmuxd 转发走回环
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return false
        }
        listenFD = fd
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                break
            }
            let connection = ServerConnection(fd: clientFD)
            delegate?.server(self, didAccept: connection)
            connection.start()
        }
    }
}
