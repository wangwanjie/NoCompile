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

    /// usbmuxd 中的一个设备条目
    struct MuxDevice {
        let id: Int
        let serial: String
        /// USB / Network
        let connectionType: String
        var isUSB: Bool { connectionType == "USB" }
    }

    /// 对设备端口发起 Connect 的结果
    private enum ConnectResult {
        /// 成功，fd 已成为到设备端口的透明隧道
        case success(Int32)
        /// 连不上 /var/run/usbmuxd
        case muxUnavailable(String)
        /// 请求发出后没有读到响应（超时或连接被关闭）
        case noResponse(String)
        /// usbmuxd 返回了非 0 的结果码
        case refused(Int)
    }

    /// usbmuxd 请求阶段的收发超时（秒）。没有超时时，一次卡住的请求会让设备轮询永远停住
    private static let muxRequestTimeout = 5

    private let onConnection: (ServerConnection) -> Void
    /// USB 真机持续一段时间没有客户端在监听时回调一次（参数：序列号、设备名），每次插入设备最多一次。
    /// 在 queue 上调用，由接收方自行切换队列
    public var onDeviceWithoutClient: ((String, String?) -> Void)?
    /// 持续多久没有客户端监听才回调（秒），避免 App 正在启动时误报
    private static let withoutClientDelay: TimeInterval = 20
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
        // 仅在 queue 上访问：已报告过连接失败的设备（DeviceID → 失败原因），原因不变时不重复写日志
        var failedDevices = [Int: String]()
        // 仅在 queue 上访问：USB 设备开始被拒绝连接（没有客户端监听）的时间，以及本次插入已经提示过的设备
        var refusedSince = [Int: Date]()
        var notifiedDevices = Set<Int>()
        while running {
            let list = listDevices()
            reportDeviceList(list)
            // 设备拔掉后移出失败集合，重新插入时可再次报告
            let present = Set((list ?? []).map { $0.id })
            failedDevices = failedDevices.filter { present.contains($0.key) }
            refusedSince = refusedSince.filter { present.contains($0.key) }
            notifiedDevices.formIntersection(present)
            // 设备拔掉后丢弃缓存的名称，重新插入时重新读取（期间可能改过名）
            let serials = Set((list ?? []).map { $0.serial })
            deviceNames = deviceNames.filter { serials.contains($0.key) }
            let busy = stateLock.withLock { connectedDevices }
            for device in Self.connectionCandidates(list ?? []) where !busy.contains(device.id) {
                // App 未运行时 Connect 会失败，下一轮继续尝试
                let result = connect(deviceID: device.id, port: NCProtocol.devicePort)
                guard case .success(let fd) = result else {
                    let reason = Self.describeFailure(result, device: device)
                    if failedDevices[device.id] != reason {
                        failedDevices[device.id] = reason
                        Diagnostics.shared.log("真机", reason, level: .warning)
                    }
                    // USB 通道正常但设备上没有进程监听：持续一段时间后提示一次
                    if device.isUSB, case .refused(3) = result {
                        let since = refusedSince[device.id] ?? Date()
                        refusedSince[device.id] = since
                        if Date().timeIntervalSince(since) >= Self.withoutClientDelay, notifiedDevices.insert(device.id).inserted {
                            onDeviceWithoutClient?(device.serial, deviceName(of: device))
                        }
                    } else {
                        refusedSince[device.id] = nil
                    }
                    continue
                }
                failedDevices[device.id] = nil
                refusedSince[device.id] = nil
                Diagnostics.shared.log("真机", "设备 \(device.id)（\(device.connectionType)）已通过 usbmuxd 连接，等待 App 握手")
                stateLock.withLock { _ = connectedDevices.insert(device.id) }
                let connection = ServerConnection(fd: fd)
                connection.usbSerial = device.serial
                connection.usbDeviceName = deviceName(of: device)
                // 连接断开后释放该设备，允许 App 重启后重连
                connection.onClose = { [weak self] in
                    guard let self else { return }
                    self.stateLock.withLock { _ = self.connectedDevices.remove(device.id) }
                }
                onConnection(connection)
                connection.start()
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// 设备名（Xcode 中显示的名称），按序列号缓存，仅在 queue 上访问
    private var deviceNames: [String: String] = [:]

    /// 读取设备名：经 usbmuxd 连到设备的 lockdownd（62078）发 GetValue DeviceName，该键无需配对会话即可读取。
    /// 读取失败时返回 nil，界面退回显示 App 上报的名称
    private func deviceName(of device: MuxDevice) -> String? {
        if let cached = deviceNames[device.serial] {
            return cached
        }
        guard case .success(let fd) = connect(deviceID: device.id, port: Self.lockdownPort) else {
            return nil
        }
        defer { Darwin.close(fd) }
        // 隧道 fd 已取消超时，这里只做一问一答，重新设上超时避免设备不应答时卡住轮询
        setTimeout(fd: fd, seconds: Self.muxRequestTimeout)
        let request: [String: Any] = ["Label": "NoCompile", "Request": "GetValue", "Key": "DeviceName"]
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) else {
            return nil
        }
        // lockdown 消息：4 字节大端长度 + plist
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        guard writeFully(fd: fd, data: data), let header = readFully(fd: fd, count: 4) else {
            return nil
        }
        let bodyLength = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard bodyLength > 0, bodyLength < 1024 * 1024, let body = readFully(fd: fd, count: bodyLength),
              let response = (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any],
              let name = response["Value"] as? String, !name.isEmpty else {
            Diagnostics.shared.log("真机", "读取设备 \(device.serial) 的名称失败，将显示 App 上报的名称", level: .warning)
            return nil
        }
        deviceNames[device.serial] = name
        Diagnostics.shared.log("真机", "设备 \(device.serial) 名称：\(name)")
        return name
    }

    /// 本轮要尝试连接的设备：USB 排在前面；同一序列号已有 USB 条目时不再走网络条目。
    /// iOS 17 起开启「通过网络连接」的设备会在 usbmuxd 里同时出现 USB 与 Network 两条（DeviceID 不同），
    /// 网络条目要经 Wi-Fi 连到设备 IP，而 App 只在回环上监听，必然失败；在部分网络环境下 usbmuxd
    /// 还要等 TCP 超时才返回，会拖住整轮轮询，导致 USB 那条迟迟连不上
    static func connectionCandidates(_ devices: [MuxDevice]) -> [MuxDevice] {
        let usbSerials = Set(devices.filter { $0.isUSB }.map { $0.serial })
        let usb = devices.filter { $0.isUSB }
        let others = devices.filter { !$0.isUSB && !usbSerials.contains($0.serial) }
        return usb + others
    }

    /// 连接失败时写入诊断日志的说明，带上 usbmuxd 返回码，便于区分「App 没在监听」和「设备 / 通道不可用」
    private static func describeFailure(_ result: ConnectResult, device: MuxDevice) -> String {
        let prefix = "设备 \(device.id)（\(device.connectionType)，\(device.serial)）连接端口 \(NCProtocol.devicePort) 失败："
        switch result {
        case .success:
            return prefix + "未知"
        case .muxUnavailable(let detail):
            return prefix + "无法连接 usbmuxd（\(detail)）"
        case .noResponse(let detail):
            return prefix + "usbmuxd 未响应 Connect 请求（\(detail)），将继续重试"
        case .refused(let number):
            var reason = "usbmuxd 返回 \(number)（\(muxResultName(number))）"
            if device.isUSB {
                reason += "。App 未运行、未包含 NoCompile 客户端（需 Debug 构建），或客户端没有在设备上监听该端口，将继续重试"
            } else {
                reason += "。该设备在 usbmuxd 中只有网络条目：真机热重载需要用数据线连接，"
                    + "或在 scheme 里设置环境变量 NOCOMPILE_HOST=<Mac 的 IP> 走 Wi-Fi"
            }
            return prefix + reason
        }
    }

    /// usbmuxd Result 消息的返回码含义
    private static func muxResultName(_ number: Int) -> String {
        switch number {
        case 0: return "成功"
        case 1: return "BadCommand"
        case 2: return "BadDevice，设备不可用或该通道不支持连接此端口"
        case 3: return "ConnectionRefused，设备上没有进程监听该端口"
        case 6: return "BadVersion"
        default: return "未知"
        }
    }

    private let stateLock = NSLock()

    // MARK: - usbmuxd 原语

    private static let muxSocketPath = "/var/run/usbmuxd"
    /// 设备上 lockdownd 的端口
    private static let lockdownPort: UInt16 = 62078
    /// 最近一次连接 usbmuxd 失败的原因，仅在 queue 上访问
    private var lastMuxError = ""

    /// 连接 usbmuxd 并设置请求阶段的收发超时；失败时把原因记在 lastMuxError
    private func openMuxSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastMuxError = "socket() 失败：\(String(cString: strerror(errno)))"
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.muxSocketPath
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
            let code = errno
            Darwin.close(fd)
            // 套接字文件被删除（清理工具误删 /var/run 等）时 usbmuxd 仍在运行，但按路径已连不上，重启 Mac 才会重建
            let exists = FileManager.default.fileExists(atPath: path)
            lastMuxError = "connect \(path) 失败：\(String(cString: strerror(code)))（errno \(code)）"
                + (exists ? "" : "，套接字文件不存在")
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd: fd, seconds: Self.muxRequestTimeout)
        return fd
    }

    /// 设置收发超时，seconds 为 0 表示取消超时（恢复为一直阻塞）
    private func setTimeout(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
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
        // usbmuxd 的响应是很小的 plist，异常的长度字段不能导致分配数 GB 内存
        guard bodyLength > 0, bodyLength <= 4 * 1024 * 1024, let body = readFully(fd: fd, count: bodyLength) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
    }

    /// 返回 usbmuxd 中已连接的设备；usbmuxd 不可达或没有响应时返回 nil
    private func listDevices() -> [MuxDevice]? {
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
            lastMuxError = "ListDevices 没有响应（\(String(cString: strerror(errno)))）"
            return nil
        }
        var devices: [MuxDevice] = []
        if let deviceList = response["DeviceList"] as? [[String: Any]] {
            for device in deviceList {
                guard let id = device["DeviceID"] as? Int else {
                    continue
                }
                let properties = device["Properties"] as? [String: Any]
                devices.append(MuxDevice(id: id,
                                         serial: properties?["SerialNumber"] as? String ?? "\(id)",
                                         connectionType: properties?["ConnectionType"] as? String ?? "未知"))
            }
        }
        return devices
    }

    /// 列表内容变化时写一条日志（usbmuxd 不可达、无设备、发现设备三种状态）
    private func reportDeviceList(_ devices: [MuxDevice]?) {
        let summary: String
        var level = Diagnostics.Level.info
        if let devices {
            let items = devices.map { "\($0.id)/\($0.connectionType)/\($0.serial)" }
            summary = devices.isEmpty
                ? "usbmuxd 中没有已连接的 iOS 设备"
                : "usbmuxd 发现 \(devices.count) 个设备条目（DeviceID/连接方式/序列号：\(items.joined(separator: ", "))）"
        } else {
            summary = "无法使用 usbmuxd（\(lastMuxError)），真机暂不可用"
            level = .warning
        }
        guard summary != lastDeviceSummary else {
            return
        }
        lastDeviceSummary = summary
        Diagnostics.shared.log("真机", summary, level: level)
    }

    /// 连接设备端口，成功时返回的 fd 成为到设备端口的透明隧道
    private func connect(deviceID: Int, port: UInt16) -> ConnectResult {
        guard let fd = openMuxSocket() else {
            return .muxUnavailable(lastMuxError)
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
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            return .noResponse(detail)
        }
        let number = response["Number"] as? Int ?? -1
        guard number == 0 else {
            Darwin.close(fd)
            return .refused(number)
        }
        // 隧道上的读循环会长期阻塞等待，必须取消请求阶段的超时，否则空闲 5 秒就会被当成断开
        setTimeout(fd: fd, seconds: 0)
        return .success(fd)
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
