//
//  Engine.swift
//  编排：监听文件 → 重编 → 推送注入。被 CLI 与菜单栏 App 共用。
//
//  线程约定：内部状态只在 workQueue 上读写；所有 delegate 回调都在主线程触发，
//  UI 层可直接操作 AppKit / SwiftUI。
//

import Foundation

public enum EngineState: Equatable {
    case idle           // 空闲（绿）
    case working        // 执行中（黄）
    case error(String)  // 出错（红）
}

/// 已连接 App 的概要信息（供界面展示）
public struct ClientSummary: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let platform: String         // simulator / device / macosx
    public let platformTitle: String    // 模拟器 / 真机 / macOS
    public let bundleID: String
    public let machine: String
}

/// 一次注入的记录（供界面展示）
public struct InjectionRecord: Identifiable {
    public let id = UUID()
    public let file: String
    public let clientName: String
    public let platformTitle: String
    public let success: Bool
    public let duration: TimeInterval
    public let message: String
    public let refreshed: [String]
    public let date = Date()
}

public protocol EngineDelegate: AnyObject {
    func engine(_ engine: Engine, didChangeState state: EngineState)
    func engine(_ engine: Engine, didLog message: String, level: Int)
    func engine(_ engine: Engine, didUpdateClientCount count: Int)
    func engine(_ engine: Engine, didUpdateClients clients: [ClientSummary])
    func engine(_ engine: Engine, didRecord record: InjectionRecord)
    func engine(_ engine: Engine, didUpdatePendingFiles files: [String])
}

/// 可选回调的默认实现，CLI 等简单场景无需实现
public extension EngineDelegate {
    func engine(_ engine: Engine, didUpdateClients clients: [ClientSummary]) {}
    func engine(_ engine: Engine, didRecord record: InjectionRecord) {}
    func engine(_ engine: Engine, didUpdatePendingFiles files: [String]) {}
}

public final class Engine: ServerDelegate, ServerConnectionDelegate {

    public let projectPath: String
    public let customDerivedData: String?
    public weak var delegate: EngineDelegate?

    /// 保存即注入（默认开）。关闭后改动会累积为"待注入"，由 triggerPendingInjection 手动触发
    public var injectsOnSave: Bool = true
    /// 是否监听头文件变更
    public var watchesHeaders: Bool = true
    /// 是否热重载资源文件（storyboard、xib、图片）
    public var watchesResources: Bool = true
    /// 路径中包含这些关键字的文件不触发注入（如 "Pods/"、"Tests/"）
    public var excludedKeywords: [String] = []
    /// 下发给 App 端的偏好设置，变更后立即推送给所有已连接的 App
    public var clientConfig: [String: Any] = [:] {
        didSet {
            let config = clientConfig
            workQueue.async { [weak self] in
                self?.connections.forEach { $0.send(NCMessage(type: .config, json: ["config": config])) }
            }
        }
    }

    private var buildLog: BuildLog?
    private var commands = ParsedCommands()
    private var lastParsedLogDate: Date = .distantPast
    private var signingIdentity: String?
    private let recompiler: Recompiler
    private let resourceCompiler: ResourceCompiler
    private var server: Server?
    private var deviceBridge: DeviceBridge?
    private var watcher: FileWatcher?
    private var connections: [ServerConnection] = []
    private var pendingFiles = Set<String>()
    /// 已推送、等待 App 回报结果的注入：键为 "连接标识|源文件"，值为（开始时间, 编译耗时）
    private var inflight: [String: (start: Date, compile: TimeInterval)] = [:]
    private let workQueue = DispatchQueue(label: "com.nocompile.engine")

    public static let outputDirectory = NSTemporaryDirectory() + "NoCompile"

    public init(projectPath: String, customDerivedData: String? = nil) {
        self.projectPath = projectPath
        self.customDerivedData = customDerivedData
        self.recompiler = Recompiler(outputDirectory: Self.outputDirectory)
        self.resourceCompiler = ResourceCompiler(outputDirectory: Self.outputDirectory + "/Resources")
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
        workQueue.sync {
            connections.forEach { $0.close() }
            connections.removeAll()
        }
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

        let platforms = Set(commands.swiftModules.map { $0.platform } + commands.allClangCommands.map { $0.platform })
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
        // 工程位于"文稿 / 桌面 / 下载"等受保护目录时，未获授权的 App 读不到文件，FSEvents 也会静默失效。
        // 放到后台队列检查：首次访问可能弹出系统授权框，不能阻塞主线程
        workQueue.async { [weak self] in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: projectDir)
            } catch {
                self?.log("无法读取工程目录（\(error.localizedDescription)）。若工程在「文稿」「桌面」「下载」中，"
                    + "请在 系统设置 → 隐私与安全性 → 文件与文件夹 中允许 NoCompile 访问，"
                    + "或在 完全磁盘访问权限 中添加 NoCompile，然后重启 NoCompile", level: 3)
            }
        }
        let watcher = FileWatcher(directories: [projectDir]) { [weak self] changed in
            self?.handleChangedFiles(changed)
        }
        watcher.start()
        self.watcher = watcher
        log("监听目录：\(projectDir)", level: 0)
    }

    // MARK: - 文件变更

    private func handleChangedFiles(_ files: [String]) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let accepted = files.filter { path in
                !self.excludedKeywords.contains { !$0.isEmpty && path.contains($0) }
            }
            guard !accepted.isEmpty else {
                return
            }
            if self.injectsOnSave {
                self.inject(files: accepted)
            } else {
                self.pendingFiles.formUnion(accepted)
                self.notifyPendingFiles()
                self.log("已记录 \(accepted.count) 个改动，等待手动注入", level: 0)
            }
        }
    }

    /// 手动注入指定文件
    public func triggerInjection(files: [String]) {
        workQueue.async { [weak self] in
            self?.inject(files: files)
        }
    }

    /// 手动注入累积的待处理改动（"保存即注入"关闭时使用）
    public func triggerPendingInjection() {
        workQueue.async { [weak self] in
            guard let self, !self.pendingFiles.isEmpty else { return }
            let files = Array(self.pendingFiles)
            self.pendingFiles.removeAll()
            self.notifyPendingFiles()
            self.inject(files: files)
        }
    }

    private func inject(files: [String]) {
        guard !connections.isEmpty else {
            log("没有已连接的 App，跳过：\(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))", level: 2)
            return
        }
        refreshCommandsIfNeeded()

        // 资源文件单独处理：不依赖源码编译命令，构建日志缺失时也能下发图片
        let resources = files.filter { ResourceCompiler.isResource($0) }
        if !resources.isEmpty {
            if watchesResources {
                pushResources(resources.sorted())
            }
        }
        let codeFiles = files.filter { !ResourceCompiler.isResource($0) }
        guard !codeFiles.isEmpty, let buildLog else {
            return
        }

        // 展开头文件变更到实现文件
        var sources = Set<String>()
        for file in codeFiles {
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
            // 同一平台、同一架构的多个连接共用一次编译结果
            var builtByPlatform: [String: (result: RecompileResult, elapsed: TimeInterval)] = [:]
            for connection in connections {
                guard let platform = platform(for: connection) else {
                    continue
                }
                let built: (result: RecompileResult, elapsed: TimeInterval)
                let buildKey = "\(platform.name)|\(platform.arch)"
                if let cached = builtByPlatform[buildKey] {
                    built = cached
                } else {
                    let start = Date()
                    let result = recompiler.recompile(sourceFile: source, commands: commands,
                                                      platform: platform, codesignIdentity: signingIdentity)
                    built = (result, Date().timeIntervalSince(start))
                    builtByPlatform[buildKey] = built
                }
                if built.result.succeeded, let dylibPath = built.result.dylibPath {
                    inflight[inflightKey(connection, source)] = (Date(), built.elapsed)
                    sendInject(dylibPath: dylibPath, source: source, isNewFile: built.result.isNewFile, to: connection)
                    let newTag = built.result.isNewFile ? "（新增文件）" : ""
                    log("⚡ \(name)\(newTag) → \(connection.displayName)（编译 \(String(format: "%.2f", built.elapsed))s）", level: 0)
                } else {
                    hadError = true
                    let message = built.result.error ?? "重编失败"
                    log("❌ \(name)（\(platform.name)）：\(message)", level: 3)
                    connection.send(NCMessage(type: .status, json: ["message": "编译失败：\(name)", "state": 2]))
                    record(InjectionRecord(file: name, clientName: connection.shortName,
                                           platformTitle: connection.platformTitle, success: false,
                                           duration: built.elapsed, message: message, refreshed: []))
                }
            }
        }
        setState(hadError ? .error("编译失败，详见日志") : .idle)
    }

    private func inflightKey(_ connection: ServerConnection, _ source: String) -> String {
        return "\(connection.id)|\(source)"
    }

    private func sendInject(dylibPath: String, source: String, isNewFile: Bool, to connection: ServerConnection) {
        let dylibName = (dylibPath as NSString).lastPathComponent
        var json: [String: Any] = [
            "dylibName": dylibName,
            "sourceFiles": [source],
            "newFile": isNewFile,
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

    // MARK: - 资源

    /// 整理并下发资源文件。同一平台的多个连接共用一次 ibtool 编译结果
    private func pushResources(_ files: [String]) {
        setState(.working)
        var hadError = false
        var handledKeys = Set<String>()
        for file in files {
            // 一次保存了同一图片集的多个文件（如 @2x、@3x）时只下发一次
            guard handledKeys.insert(ResourceCompiler.batchKey(for: file)).inserted else {
                continue
            }
            let name = (file as NSString).lastPathComponent
            var preparedByPlatform: [String: (result: ResourcePreparation, elapsed: TimeInterval)] = [:]
            for connection in connections {
                guard let platform = platform(for: connection) else {
                    continue
                }
                let prepared: (result: ResourcePreparation, elapsed: TimeInterval)
                if let cached = preparedByPlatform[platform.name] {
                    prepared = cached
                } else {
                    if file.hasSuffix(".storyboard") || file.hasSuffix(".xib") {
                        notifyStatus("编译中：\(name)", state: 1)
                    }
                    let start = Date()
                    let result = resourceCompiler.prepare(file: file, commands: commands, platform: platform)
                    prepared = (result, Date().timeIntervalSince(start))
                    preparedByPlatform[platform.name] = prepared
                }
                switch prepared.result {
                case .ready(let package):
                    inflight[inflightKey(connection, file)] = (Date(), prepared.elapsed)
                    sendResource(package, to: connection)
                    log("🖼 \(name) → \(connection.displayName)（准备 \(String(format: "%.2f", prepared.elapsed))s）", level: 0)
                case .skipped(let reason):
                    log("跳过 \(name)（\(connection.displayName)）：\(reason)", level: 0)
                case .failed(let error):
                    hadError = true
                    log("❌ \(name)：\(error)", level: 3)
                    connection.send(NCMessage(type: .status, json: ["message": "资源处理失败：\(name)", "state": 2]))
                    record(InjectionRecord(file: name, clientName: connection.shortName,
                                           platformTitle: connection.platformTitle, success: false,
                                           duration: prepared.elapsed, message: error, refreshed: []))
                }
            }
        }
        setState(hadError ? .error("资源处理失败，详见日志") : .idle)
    }

    /// 发送资源包。模拟器 / macOS 直接拷进 App 的 tmp 目录；真机把各文件内容拼接后随帧传输
    private func sendResource(_ package: ResourcePackage, to connection: ServerConnection) {
        var json = package.json
        var payload: Data? = nil
        if connection.isLocalFileSystem, let tmp = connection.clientInfo["tmp"] as? String, !tmp.isEmpty {
            let destination = (tmp as NSString).appendingPathComponent("NoCompileIncoming/\((package.rootDirectory as NSString).lastPathComponent)_\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(atPath: package.rootDirectory, toPath: destination)) != nil {
                json["localRoot"] = destination
            }
        }
        if json["localRoot"] == nil {
            var data = Data()
            var entries: [[String: Any]] = []
            for file in package.files {
                guard let content = FileManager.default.contents(atPath: "\(package.rootDirectory)/\(file)") else {
                    continue
                }
                entries.append(["path": file, "length": content.count])
                data.append(content)
            }
            json["files"] = entries
            payload = data
        }
        connection.send(NCMessage(type: .resource, json: json, data: payload))
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
        // 模拟器 / macOS 的 machine 即 uname 架构（arm64 / x86_64）；真机是机型标识，统一按 arm64
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
        }
    }

    public func connection(_ connection: ServerConnection, didReceive message: NCMessage) {
        switch message.type {
        case .hello:
            guard let info = message.json else {
                return
            }
            connection.updateClientInfo(info)
            workQueue.async { [weak self] in
                guard let self else { return }
                connection.send(NCMessage(type: .helloAck,
                                          json: ["protocol": NCProtocol.version, "config": self.clientConfig]))
                self.log("🔌 已连接：\(connection.displayName)", level: 1)
                self.notifyClients()
                self.refreshCommandsIfNeeded()
            }
        case .log:
            if let msg = message.json?["message"] as? String {
                let level = message.json?["level"] as? Int ?? 0
                log("[\(connection.shortName)] \(msg)", level: level)
            }
        case .injectResult, .resourceResult:
            let json = message.json ?? [:]
            workQueue.async { [weak self] in
                self?.handleInjectResult(json, from: connection)
            }
        default:
            break
        }
    }

    /// App 回报注入结果：结合编译耗时生成一条记录（日志已由 App 端转发，这里不再重复打印）
    private func handleInjectResult(_ json: [String: Any], from connection: ServerConnection) {
        let ok = json["ok"] as? Bool ?? false
        let source = (json["sourceFiles"] as? [String])?.first ?? ""
        let refreshed = json["refreshed"] as? [String] ?? []
        let key = inflightKey(connection, source)
        let started = inflight.removeValue(forKey: key)
        let total = started.map { $0.compile + Date().timeIntervalSince($0.start) } ?? 0
        record(InjectionRecord(file: (source as NSString).lastPathComponent,
                               clientName: connection.shortName,
                               platformTitle: connection.platformTitle,
                               success: ok,
                               duration: total,
                               message: json["message"] as? String ?? "",
                               refreshed: refreshed))
    }

    public func connectionDidClose(_ connection: ServerConnection) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.connections.removeAll { $0 === connection }
            if !connection.clientInfo.isEmpty {
                self.log("断开：\(connection.displayName)", level: 2)
            }
            self.notifyClients()
        }
    }

    // MARK: - 回调（统一切到主线程）

    private func notifyClients() {
        // 只展示已完成握手的连接
        let summaries = connections.filter { !$0.clientInfo.isEmpty }.map { connection in
            ClientSummary(id: connection.id,
                          name: connection.shortName,
                          platform: connection.platformName,
                          platformTitle: connection.platformTitle,
                          bundleID: connection.clientInfo["bundleID"] as? String ?? "",
                          machine: connection.machine)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didUpdateClientCount: summaries.count)
            self.delegate?.engine(self, didUpdateClients: summaries)
        }
    }

    private func notifyPendingFiles() {
        let files = pendingFiles.sorted()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didUpdatePendingFiles: files)
        }
    }

    private func record(_ record: InjectionRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didRecord: record)
        }
    }

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
