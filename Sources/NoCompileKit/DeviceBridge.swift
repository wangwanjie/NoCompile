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
    /// 轮询是否继续，加锁访问（stop 在其他线程调用）
    private var _running = false
    private var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }
    private var connectedDevices = Set<Int>()
    private let queue = DispatchQueue(label: "com.nocompile.devicebridge")
    /// 上一次写入日志的设备列表摘要，仅在 queue 上访问；状态不变时不重复记录
    private var lastDeviceSummary = ""

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
        // 仅在 queue 上访问：已报告过连接失败的设备，避免每 2 秒重复写日志
        var failedDevices = Set<Int>()
        while running {
            let list = listDevices()
            let devices = list.map { $0.map { $0.id } }
            reportDeviceList(devices)
            // 设备拔掉后移出失败集合，重新插入时可再次报告
            failedDevices.formIntersection(devices ?? [])
            let busy = stateLock.withLock { connectedDevices }
            for (deviceID, serial) in list ?? [] where !busy.contains(deviceID) {
                // App 未运行时 Connect 会失败，下一轮继续尝试
                guard let fd = connect(deviceID: deviceID, port: NCProtocol.devicePort) else {
                    if failedDevices.insert(deviceID).inserted {
                        Diagnostics.shared.log("真机", "设备 \(deviceID) 连接端口 \(NCProtocol.devicePort) 失败："
                                               + "App 未运行，或未包含 NoCompile 客户端（需 Debug 构建），将继续重试", level: .warning)
                    }
                    continue
                }
                failedDevices.remove(deviceID)
                Diagnostics.shared.log("真机", "设备 \(deviceID) 已通过 usbmuxd 连接，等待 App 握手")
                stateLock.withLock { _ = connectedDevices.insert(deviceID) }
                let connection = ServerConnection(fd: fd)
                connection.usbSerial = serial
                // 连接断开后释放该设备，允许 App 重启后重连
                connection.onClose = { [weak self] in
                    guard let self else { return }
                    self.stateLock.withLock { _ = self.connectedDevices.remove(deviceID) }
                }
                onConnection(connection)
                connection.start()
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private let stateLock = NSLock()

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

    /// 返回 usbmuxd 中已连接的设备（DeviceID 与序列号）；usbmuxd 不可达时返回 nil
    private func listDevices() -> [(id: Int, serial: String)]? {
        guard let fd = openMuxSocket() else {
            return nil
        }
        defer { Darwin.close(fd) }
        let request: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "NoCompile",
            "ProgName": "NoCompile",
        ]
        guard sendPlist(request, over: fd, tag: 1), let response = readPlist(over: fd) else {
            return nil
        }
        var devices: [(id: Int, serial: String)] = []
        if let deviceList = response["DeviceList"] as? [[String: Any]] {
            for device in deviceList {
                guard let id = device["DeviceID"] as? Int else {
                    continue
                }
                let properties = device["Properties"] as? [String: Any]
                devices.append((id, properties?["SerialNumber"] as? String ?? "\(id)"))
            }
        }
        return devices
    }

    /// 列表内容变化时写一条日志（usbmuxd 不可达、无设备、发现设备三种状态）
    private func reportDeviceList(_ devices: [Int]?) {
        let summary: String
        var level = Diagnostics.Level.info
        if let devices {
            summary = devices.isEmpty
                ? "usbmuxd 中没有已连接的 iOS 设备"
                : "usbmuxd 发现 \(devices.count) 台设备（DeviceID：\(devices.map(String.init).joined(separator: ", "))）"
        } else {
            summary = "无法连接 usbmuxd（/var/run/usbmuxd），真机暂不可用"
            level = .warning
        }
        guard summary != lastDeviceSummary else {
            return
        }
        lastDeviceSummary = summary
        Diagnostics.shared.log("真机", summary, level: level)
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
