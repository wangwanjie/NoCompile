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
    private var recompiler: Recompiler?
    private var commands: (swiftModules: [RawCompileCommand], clangFiles: [String: RawCompileCommand])?
    private var signingIdentity: String?
    private var server: Server?
    private var deviceBridge: DeviceBridge?
    private var watcher: FileWatcher?
    private var connections: [ServerConnection] = []
    private let workQueue = DispatchQueue(label: "com.nocompile.engine")
    private let outputDirectory: String

    public init(projectPath: String, customDerivedData: String? = nil) {
        self.projectPath = projectPath
        self.customDerivedData = customDerivedData
        self.outputDirectory = NSTemporaryDirectory() + "NoCompile"
    }

    // MARK: - 生命周期

    public func start() {
        setState(.working)
        workQueue.async { [weak self] in
            self?.initializeProject()
        }
    }

    public func stop() {
        server?.stop()
        deviceBridge?.stop()
        watcher?.stop()
        connections.forEach { $0.close() }
        connections.removeAll()
    }

    private func initializeProject() {
        guard let buildLog = BuildLog.locate(projectPath: projectPath, customDerivedData: customDerivedData) else {
            setState(.error("未找到 DerivedData / 构建日志，请先在 Xcode 完整构建一次"))
            return
        }
        self.buildLog = buildLog
        log("开始解析构建日志…", level: 0)
        let text = buildLog.extractPlainText()
        self.signingIdentity = ProjectInfo.signingIdentity(fromPlainText: text)
        self.commands = buildLog.parse()
        self.recompiler = Recompiler(buildLog: buildLog, outputDirectory: outputDirectory)

        let swiftCount = commands?.swiftModules.count ?? 0
        let clangCount = commands?.clangFiles.count ?? 0
        log("解析完成：\(swiftCount) 个 Swift 模块，\(clangCount) 个 ObjC/C 文件", level: 1)

        startServer()
        startWatching()
        setState(.idle)
        log("🎉 NoCompile 就绪，保存文件即可热重载", level: 1)
    }

    private func startServer() {
        let server = Server(port: NCProtocol.macPort)
        server.delegate = self
        if server.start() {
            self.server = server
        } else {
            log("TCP 端口监听失败（\(NCProtocol.macPort) 可能被占用）", level: 3)
        }
        // 真机 USB 桥接
        let bridge = DeviceBridge { [weak self] connection in
            self?.server(self!.server ?? Server(), didAccept: connection)
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
        guard let recompiler, let commands, let buildLog else {
            return
        }
        guard !connections.isEmpty else {
            log("没有已连接的 App，跳过注入", level: 2)
            return
        }

        // 展开头文件变更到实现文件
        var sources = Set<String>()
        for file in files {
            if file.hasSuffix(".h") || file.hasSuffix(".hpp") {
                guard watchesHeaders else { continue }
                let impls = ProjectInfo.implementationFiles(dependingOn: file, derivedDataPath: buildLog.derivedDataPath)
                sources.formUnion(impls)
            } else {
                sources.insert(file)
            }
        }
        guard !sources.isEmpty else {
            return
        }

        setState(.working)
        defer { setState(.idle) }

        // 每个连接的平台各重编一次（模拟器 / 真机 arch 不同）
        for source in sources {
            notifyStatus("编译中：\((source as NSString).lastPathComponent)", state: 1)
            for connection in connections {
                guard let platform = platform(for: connection) else {
                    continue
                }
                let result = recompiler.recompile(sourceFile: source, commands: commands,
                                                  platform: platform, codesignIdentity: signingIdentity)
                if result.succeeded, let dylibPath = result.dylibPath {
                    sendInject(dylibPath: dylibPath, source: source, to: connection)
                    log("✅ \((source as NSString).lastPathComponent) → \(connection.platformName)", level: 1)
                } else {
                    let message = result.error ?? "重编失败"
                    log("❌ \((source as NSString).lastPathComponent)：\(message)", level: 3)
                    notifyStatus("编译失败", state: 2)
                    setState(.error(message))
                }
            }
        }
    }

    private func sendInject(dylibPath: String, source: String, to connection: ServerConnection) {
        let dylibName = (dylibPath as NSString).lastPathComponent
        var json: [String: Any] = [
            "dylibName": dylibName,
            "sourceFiles": [source],
        ]
        var payload: Data? = nil
        if connection.isLocalFileSystem {
            // 共享文件系统：把路径告诉客户端即可
            json["localPath"] = dylibPath
        } else {
            // 真机：随帧传输 dylib 字节
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
            name = "iphonesimulator"; isSimulator = true; isDevice = false
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
                let bundleID = info["bundleID"] as? String ?? "?"
                log("已连接：\(bundleID)（\(connection.platformName)）", level: 1)
            }
        case .log:
            if let msg = message.json?["message"] as? String {
                let level = message.json?["level"] as? Int ?? 0
                log("[App] \(msg)", level: level)
            }
        case .injectResult:
            if let ok = message.json?["ok"] as? Bool, !ok {
                let msg = message.json?["message"] as? String ?? ""
                log("App 注入失败：\(msg)", level: 3)
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
