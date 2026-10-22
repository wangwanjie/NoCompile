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
    private let port: UInt16
    /// running 由主线程（start / stop）与接受线程共同访问，用锁保护
    private let lock = NSLock()
    private var _running = false
    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _running
    }

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
        guard bindResult == 0, listen(fd, 16) == 0 else {
            // 保留 bind / listen 的 errno（如 EADDRINUSE），调用方据此判断是否已有另一个实例在运行
            let code = errno
            Darwin.close(fd)
            errno = code
            return false
        }
        lock.lock()
        _running = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
        return true
    }

    /// 停止接受新连接。监听描述符由接受线程退出循环后自己关闭：
    /// 在别的线程直接 close 会让接受线程拿着一个可能已被复用的描述符号继续 accept
    public func stop() {
        lock.lock()
        _running = false
        lock.unlock()
    }

    private func acceptLoop(listenFD: Int32) {
        defer {
            Darwin.close(listenFD)
        }
        var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        while running {
            // 带超时等待，便于及时察觉 stop
            pollFD.revents = 0
            let ready = poll(&pollFD, 1, 500)
            if ready == 0 {
                continue
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                Diagnostics.shared.log("连接", "监听端口 \(port) 的 poll 失败（errno \(errno)），停止接受连接", level: .error)
                return
            }
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let code = errno
                switch code {
                case EINTR, EAGAIN, ECONNABORTED:
                    // 客户端在握手完成前就断开（如 App 刚启动即崩溃）等瞬时错误：继续接受下一个连接
                    continue
                case EMFILE, ENFILE:
                    // 描述符耗尽：稍等再试，不能就此退出，否则之后所有 App 都连不上
                    Diagnostics.shared.log("连接", "accept 失败：描述符已耗尽（errno \(code)），1 秒后重试", level: .warning)
                    Thread.sleep(forTimeInterval: 1)
                    continue
                default:
                    Diagnostics.shared.log("连接", "accept 失败（errno \(code)），停止接受连接", level: .error)
                    return
                }
            }
            if !running {
                Darwin.close(clientFD)
                return
            }
            let connection = ServerConnection(fd: clientFD)
            delegate?.server(self, didAccept: connection)
            connection.start()
        }
    }
}
