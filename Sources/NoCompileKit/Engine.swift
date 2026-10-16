//
//  Engine.swift
//  编排：监听文件 → 重编 → 推送注入。被 CLI 与菜单栏 App 共用。
//

import Foundation

public enum EngineState: Equatable {
    case idle           // 空闲（绿）
    case working        // 执行中（黄）
    case error(String)  // 出错（红）
}

public protocol EngineDelegate: AnyObject {
    func engine(_ engine: Engine, didChangeState state: EngineState)
    func engine(_ engine: Engine, didLog message: String, level: Int)
    func engine(_ engine: Engine, didUpdateClientCount count: Int)
}

public final class Engine: ServerDelegate, ServerConnectionDelegate {

    public let projectPath: String
    public let customDerivedData: String?
    public weak var delegate: EngineDelegate?

    /// 保存即注入（默认开）。关闭后需手动调用 triggerInjection
    public var injectsOnSave: Bool = true
    /// 是否监听头文件变更
    public var watchesHeaders: Bool = true

    private var buildLog: BuildLog?
    private var commands = ParsedCommands()
    private var lastParsedLogDate: Date = .distantPast
    private var signingIdentity: String?
    private let recompiler: Recompiler
    private var server: Server?
    private var deviceBridge: DeviceBridge?
    private var watcher: FileWatcher?
    private var connections: [ServerConnection] = []
    private let workQueue = DispatchQueue(label: "com.nocompile.engine")

    public init(projectPath: String, customDerivedData: String? = nil) {
        self.projectPath = projectPath
        self.customDerivedData = customDerivedData
        self.recompiler = Recompiler(outputDirectory: NSTemporaryDirectory() + "NoCompile")
    }

    // MARK: - 生命周期

    public func start() {
        setState(.working)
        startServer()
        startWatching()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.refreshCommandsIfNeeded()
            self.setState(.idle)
            self.log("🎉 NoCompile 就绪，保存文件即可热重载", level: 1)
        }
    }

    public func stop() {
        server?.stop()
        deviceBridge?.stop()
        watcher?.stop()
        connections.forEach { $0.close() }
        connections.removeAll()
    }

    /// 定位日志；若出现了更新的构建日志则重新解析（例如先跑真机、再跑模拟器）
    private func refreshCommandsIfNeeded() {
        if buildLog == nil {
            buildLog = BuildLog.locate(projectPath: projectPath, customDerivedData: customDerivedData)
            if buildLog == nil {
                log("尚未找到构建日志，请先在 Xcode 构建并运行一次", level: 2)
                return
            }
            log("DerivedData：\(buildLog!.derivedDataPath)", level: 0)
        }
        guard let buildLog else {
            return
        }
        let latest = buildLog.latestLogDate()
        guard latest > lastParsedLogDate else {
            return
        }
        log("解析构建日志…", level: 0)
        let text = buildLog.extractPlainText()
        commands = BuildLog.parse(plainText: text)
        signingIdentity = ProjectInfo.signingIdentity(fromPlainText: text)
        lastParsedLogDate = latest

        let platforms = Set(commands.swiftModules.map { $0.platform } + commands.clangFiles.values.map { $0.platform })
            .filter { $0 != "unknown" }.sorted()
        log("解析完成：\(commands.swiftModules.count) 条 Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件，平台：\(platforms.joined(separator: ", "))", level: 1)
    }

    private func startServer() {
        let server = Server(port: NCProtocol.macPort)
        server.delegate = self
        if server.start() {
            self.server = server
        } else {
            log("TCP 端口 \(NCProtocol.macPort) 监听失败，可能已有另一个 NoCompile 在运行", level: 3)
        }
        // 真机 USB 桥接：经 usbmuxd 连接设备上的客户端
        let bridge = DeviceBridge { [weak self] connection in
            self?.accept(connection)
        }
        bridge.start()
        self.deviceBridge = bridge
    }

    private func startWatching() {
        let projectDir = (projectPath as NSString).deletingLastPathComponent
        let watcher = FileWatcher(directories: [projectDir]) { [weak self] changed in
            self?.handleChangedFiles(changed)
        }
        watcher.start()
        self.watcher = watcher
        log("监听目录：\(projectDir)", level: 0)
    }

    // MARK: - 文件变更

    private func handleChangedFiles(_ files: [String]) {
        guard injectsOnSave else {
            return
        }
        workQueue.async { [weak self] in
            self?.inject(files: files)
        }
    }

    /// 手动触发（供快捷键 / CLI 使用）
    public func triggerInjection(files: [String]) {
        workQueue.async { [weak self] in
            self?.inject(files: files)
        }
    }

    private func inject(files: [String]) {
        guard !connections.isEmpty else {
            log("没有已连接的 App，跳过：\(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))", level: 2)
            return
        }
        refreshCommandsIfNeeded()
        guard let buildLog else {
            return
        }

        // 展开头文件变更到实现文件
        var sources = Set<String>()
        for file in files {
            if file.hasSuffix(".h") || file.hasSuffix(".hpp") {
                guard watchesHeaders else {
                    continue
                }
                let impls = ProjectInfo.implementationFiles(dependingOn: file, derivedDataPath: buildLog.derivedDataPath)
                if !impls.isEmpty {
                    log("头文件 \((file as NSString).lastPathComponent) 影响 \(impls.count) 个实现文件", level: 0)
                }
                sources.formUnion(impls)
            } else {
                sources.insert(file)
            }
        }
        guard !sources.isEmpty else {
            return
        }

        setState(.working)
        var hadError = false

        for source in sources.sorted() {
            let name = (source as NSString).lastPathComponent
            notifyStatus("编译中：\(name)", state: 1)
            // 同一平台的多个连接共用一次编译结果
            var builtByPlatform: [String: RecompileResult] = [:]
            for connection in connections {
                guard let platform = platform(for: connection) else {
                    continue
                }
                let start = Date()
                let result: RecompileResult
                if let cached = builtByPlatform[platform.name] {
                    result = cached
                } else {
                    result = recompiler.recompile(sourceFile: source, commands: commands,
                                                  platform: platform, codesignIdentity: signingIdentity)
                    builtByPlatform[platform.name] = result
                }
                if result.succeeded, let dylibPath = result.dylibPath {
                    let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
                    sendInject(dylibPath: dylibPath, source: source, to: connection)
                    log("⚡ \(name) → \(connection.displayName)（编译 \(elapsed)s）", level: 1)
                } else {
                    hadError = true
                    let message = result.error ?? "重编失败"
                    log("❌ \(name)（\(platform.name)）：\(message)", level: 3)
                    connection.send(NCMessage(type: .status, json: ["message": "编译失败：\(name)", "state": 2]))
                }
            }
        }
        setState(hadError ? .error("编译失败，详见日志") : .idle)
    }

    private func sendInject(dylibPath: String, source: String, to connection: ServerConnection) {
        let dylibName = (dylibPath as NSString).lastPathComponent
        var json: [String: Any] = [
            "dylibName": dylibName,
            "sourceFiles": [source],
        ]
        var payload: Data? = nil
        if connection.isLocalFileSystem, let tmp = connection.clientInfo["tmp"] as? String, !tmp.isEmpty {
            // 模拟器 / macOS：与 Mac 共享文件系统，直接拷进 App 自己的 tmp 目录，避免沙盒读权限问题
            let destination = (tmp as NSString).appendingPathComponent(dylibName)
            try? FileManager.default.removeItem(atPath: destination)
            do {
                try FileManager.default.copyItem(atPath: dylibPath, toPath: destination)
                json["localPath"] = destination
            } catch {
                payload = try? Data(contentsOf: URL(fileURLWithPath: dylibPath))
            }
        } else {
            // 真机：随帧传输 dylib 字节，由客户端写入自己的 tmp 目录
            payload = try? Data(contentsOf: URL(fileURLWithPath: dylibPath))
        }
        connection.send(NCMessage(type: .inject, json: json, data: payload))
    }

    private func platform(for connection: ServerConnection) -> Platform? {
        let name: String
        let isSimulator: Bool
        let isDevice: Bool
        switch connection.platformName {
        case "simulator":
            name = "iphonesimulator"; isSimulator = true; isDevice = false
        case "device":
            name = "iphoneos"; isSimulator = false; isDevice = true
        case "macosx":
            name = "macosx"; isSimulator = false; isDevice = false
        default:
            log("未知的客户端平台：\(connection.platformName)", level: 3)
            return nil
        }
        guard let sdkPath = ProjectInfo.sdkPath(for: name) else {
            log("无法定位 \(name) SDK", level: 3)
            return nil
        }
        let arch = connection.machine.hasPrefix("x86") ? "x86_64" : "arm64"
        return Platform(name: name, sdkPath: sdkPath, arch: arch, isSimulator: isSimulator, isDevice: isDevice)
    }

    private func notifyStatus(_ message: String, state: Int) {
        let json: [String: Any] = ["message": message, "state": state]
        connections.forEach { $0.send(NCMessage(type: .status, json: json)) }
    }

    // MARK: - ServerDelegate / ServerConnectionDelegate

    public func server(_ server: Server, didAccept connection: ServerConnection) {
        accept(connection)
    }

    private func accept(_ connection: ServerConnection) {
        connection.delegate = self
        workQueue.async { [weak self] in
            guard let self else { return }
            self.connections.append(connection)
            self.delegate?.engine(self, didUpdateClientCount: self.connections.count)
        }
    }

    public func connection(_ connection: ServerConnection, didReceive message: NCMessage) {
        switch message.type {
        case .hello:
            if let info = message.json {
                connection.updateClientInfo(info)
                connection.send(NCMessage(type: .helloAck, json: ["protocol": NCProtocol.version]))
                log("🔌 已连接：\(connection.displayName)", level: 1)
                workQueue.async { [weak self] in
                    self?.refreshCommandsIfNeeded()
                }
            }
        case .log:
            if let msg = message.json?["message"] as? String {
                let level = message.json?["level"] as? Int ?? 0
                log("[\(connection.shortName)] \(msg)", level: level)
            }
        case .injectResult:
            if let ok = message.json?["ok"] as? Bool, !ok {
                let msg = message.json?["message"] as? String ?? ""
                log("[\(connection.shortName)] 注入失败：\(msg)", level: 3)
            }
        default:
            break
        }
    }

    public func connectionDidClose(_ connection: ServerConnection) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.connections.removeAll { $0 === connection }
            self.delegate?.engine(self, didUpdateClientCount: self.connections.count)
            self.log("断开：\(connection.displayName)", level: 2)
        }
    }

    // MARK: - 辅助

    private func setState(_ state: EngineState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didChangeState: state)
        }
    }

    private func log(_ message: String, level: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didLog: message, level: level)
        }
    }
}
