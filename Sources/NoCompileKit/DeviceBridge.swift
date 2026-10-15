//
//  DeviceBridge.swift
//  通过 usbmuxd 把 Mac 连接到真机 App 在回环上监听的端口（NC_DEVICE_PORT）。
//
//  usbmuxd 协议：连接 /var/run/usbmuxd，发 plist 消息。
//  先 ListDevices 拿到 DeviceID，再对每台设备发 Connect（端口为网络字节序）。
//  Connect 成功后，同一个 socket 变成到设备端口的透明隧道。
//

import Foundation

public final class DeviceBridge {

    private let onConnection: (ServerConnection) -> Void
    private var running = false
    private var connectedDevices = Set<Int>()
    private let queue = DispatchQueue(label: "com.nocompile.devicebridge")

    public init(onConnection: @escaping (ServerConnection) -> Void) {
        self.onConnection = onConnection
    }

    public func start() {
        running = true
        queue.async { [weak self] in
            self?.pollLoop()
        }
    }

    public func stop() {
        running = false
    }

    private func pollLoop() {
        while running {
            let devices = listDevices()
            for deviceID in devices where !connectedDevices.contains(deviceID) {
                if let fd = connect(deviceID: deviceID, port: NCProtocol.devicePort) {
                    connectedDevices.insert(deviceID)
                    let connection = ServerConnection(fd: fd)
                    onConnection(connection)
                    connection.start()
                    // 监控断开：连接关闭后允许重连
                    watchDisconnect(deviceID: deviceID, connection: connection)
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func watchDisconnect(deviceID: Int, connection: ServerConnection) {
        // ServerConnection 关闭时无直接回调给 bridge，这里用轻量轮询清理
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
            guard let self else { return }
            if connection == nil {
                self.connectedDevices.remove(deviceID)
            } else {
                self.watchDisconnect(deviceID: deviceID, connection: connection!)
            }
        }
    }

    // MARK: - usbmuxd 原语

    private func openMuxSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// 发送一条 plist 消息（message=8）
    private func sendPlist(_ dict: [String: Any], over fd: Int32, tag: UInt32) -> Bool {
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return false
        }
        var header = [UInt32]()
        header.append(UInt32(16 + payload.count).littleEndian) // length
        header.append(UInt32(1).littleEndian)                  // version
        header.append(UInt32(8).littleEndian)                  // message: plist
        header.append(tag.littleEndian)                        // tag
        var data = Data()
        header.forEach { var v = $0; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(payload)
        return writeFully(fd: fd, data: data)
    }

    /// 读取一条 plist 响应
    private func readPlist(over fd: Int32) -> [String: Any]? {
        guard let headerData = readFully(fd: fd, count: 16), headerData.count == 16 else {
            return nil
        }
        let length = headerData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let bodyLength = Int(length) - 16
        guard bodyLength > 0, let body = readFully(fd: fd, count: bodyLength) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
    }

    private func listDevices() -> [Int] {
        guard let fd = openMuxSocket() else {
            return []
        }
        defer { Darwin.close(fd) }
        let request: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "NoCompile",
            "ProgName": "NoCompile",
        ]
        guard sendPlist(request, over: fd, tag: 1), let response = readPlist(over: fd) else {
            return []
        }
        var ids: [Int] = []
        if let deviceList = response["DeviceList"] as? [[String: Any]] {
            for device in deviceList {
                if let id = device["DeviceID"] as? Int {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// 连接设备端口，成功返回隧道 fd
    private func connect(deviceID: Int, port: UInt16) -> Int32? {
        guard let fd = openMuxSocket() else {
            return nil
        }
        // usbmuxd 要求端口为网络字节序
        let netPort = Int(port.bigEndian)
        let request: [String: Any] = [
            "MessageType": "Connect",
            "ClientVersionString": "NoCompile",
            "ProgName": "NoCompile",
            "DeviceID": deviceID,
            "PortNumber": netPort,
        ]
        guard sendPlist(request, over: fd, tag: 2), let response = readPlist(over: fd) else {
            Darwin.close(fd)
            return nil
        }
        if let number = response["Number"] as? Int, number == 0 {
            return fd   // 连接成功，fd 成为透明隧道
        }
        Darwin.close(fd)
        return nil
    }

    // MARK: - IO

    private func writeFully(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { raw -> Bool in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            var sent = 0
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 {
                    return false
                }
                sent += n
            }
            return true
        }
    }

    private func readFully(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            var received = 0
            while received < count {
                let n = read(fd, base + received, count - received)
                if n <= 0 {
                    return false
                }
                received += n
            }
            return true
        }
        return ok ? buffer : nil
    }
}
