//
//  Engine.swift
//  编排：监听文件 → 重编 → 推送注入。被 CLI 与菜单栏 App 共用。
//
//  线程约定：内部状态只在 workQueue 上读写；所有 delegate 回调都在主线程触发，
//  UI 层可直接操作 AppKit / SwiftUI。
//  公开方法都不会同步等待 workQueue（workQueue 上可能正在执行耗时的编译），
//  因此从主线程调用 stop() 等方法不会卡住界面。
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
    /// 客户端版本，旧版客户端为 nil
    public var clientVersion: String? = nil
    /// 与 Mac 端不兼容的原因（需要重新编译 App），兼容为 nil
    public var compatibilityIssue: String? = nil
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
    /// 受影响但未自动重建的已加载页面，需退出页面后重新进入才能看到改动
    public var pending: [String] = []
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
    /// 头文件被超过这么多实现文件引用时，只重编与它同名的实现文件（如 Foo.h → Foo.m），
    /// 避免改一个公共头文件就重编成百上千个文件
    public var maxHeaderDependents: Int = 10
    /// 一批改动中的源文件超过这个数量（多半是切换分支）时不再逐个注入，提示重新编译
    public var maxBatchSourceFiles: Int = 100
    /// Mac 端随附的客户端 bundle 所在目录，用于判断 App 内拷贝的 bundle 是否过期。默认取主 bundle 的资源目录
    public var bundledClientDirectory: String? = Bundle.main.resourcePath
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
    /// 已解析过的日志及其修改时间，只解析新出现 / 有变化的日志
    private var parsedLogs: [String: Date] = [:]
    private var headerIndex: HeaderDependencyIndex?
    private let headerAnalyzer = HeaderChangeAnalyzer()
    private let recompiler: Recompiler
    private let resourceCompiler: ResourceCompiler
    private var server: Server?
    private var deviceBridge: DeviceBridge?
    private var watcher: FileWatcher?
    private var watchRoots: [String] = []
    private var connections: [ServerConnection] = []
    /// 所有已接受的连接（加锁访问）：stop() 时不经 workQueue 立即关闭，
    /// 让客户端尽快重连到新引擎，不必等旧引擎手头的编译结束
    private var liveConnections: [ServerConnection] = []
    private let liveConnectionsLock = NSLock()
    private var pendingFiles = Set<String>()
    /// 已推送、等待 App 回报结果的注入：键为 "连接标识|源文件"，值为（开始时间, 编译耗时）
    private var inflight: [String: (start: Date, compile: TimeInterval)] = [:]
    private let workQueue = DispatchQueue(label: "com.nocompile.engine")
    /// stop() 之后置位：迟到的文件事件、连接、回调一律忽略
    private var stopped = false
    private let stoppedLock = NSLock()
    private var isStopped: Bool {
        stoppedLock.lock()
        defer { stoppedLock.unlock() }
        return stopped
    }

    public static let outputDirectory = NSTemporaryDirectory() + "NoCompile"

    public init(projectPath: String, customDerivedData: String? = nil) {
        self.projectPath = projectPath
        self.customDerivedData = customDerivedData
        self.recompiler = Recompiler(outputDirectory: Self.outputDirectory)
        self.resourceCompiler = ResourceCompiler(outputDirectory: Self.outputDirectory + "/Resources")
    }

    // MARK: - 生命周期

    public func start() {
        Diagnostics.shared.log("引擎", "启动：\(projectPath)，DerivedData：\(customDerivedData ?? "自动检测")")
        setState(.working)
        startServer()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.startWatching()
            self.refreshCommandsIfNeeded()
            self.setState(.idle)
            self.log("🎉 NoCompile 就绪，保存文件即可热重载", level: 1)
        }
    }

    /// 停止引擎。不等待 workQueue：正在进行的编译结束后自然退出，不会卡住调用方（主线程）
    public func stop() {
        stoppedLock.lock()
        stopped = true
        stoppedLock.unlock()
        Diagnostics.shared.log("引擎", "停止：\(projectPath)")
        server?.stop()
        deviceBridge?.stop()
        liveConnectionsLock.lock()
        let live = liveConnections
        liveConnections.removeAll()
        liveConnectionsLock.unlock()
        live.forEach { $0.close() }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.watcher?.stop()
            self.watcher = nil
            self.connections.removeAll()
        }
    }

    /// 定位日志；只解析新出现或有变化的日志，并与已有结果合并（例如先跑真机、再跑模拟器）
    private func refreshCommandsIfNeeded() {
        if buildLog == nil {
            buildLog = BuildLog.locate(projectPath: projectPath, customDerivedData: customDerivedData)
            guard let buildLog else {
                log("尚未找到构建日志，请先在 Xcode 构建并运行一次", level: 2)
                Diagnostics.shared.log("解析日志", "未找到构建日志：\(projectPath)，自定义 DerivedData：\(customDerivedData ?? "无")", level: .warning)
                return
            }
            log("DerivedData：\(buildLog.derivedDataPath)", level: 0)
            headerIndex = HeaderDependencyIndex(derivedDataPath: buildLog.derivedDataPath)
            // 载入上次保存的命令：Xcode 清理掉的旧日志里的命令仍然可用，也省去重新解析全部日志
            if let cached = CommandCache.load(derivedDataPath: buildLog.derivedDataPath) {
                commands = cached.commands
                parsedLogs = cached.parsedLogs
                log("载入命令缓存：\(commands.swiftModules.count) 条 Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件", level: 0)
            }
        }
        guard let buildLog else {
            return
        }
        let logs = buildLog.logFiles()
        let changed = logs.filter { path in
            let date = BuildLog.modificationDate(of: path)
            return parsedLogs[path] != date
        }
        guard !changed.isEmpty else {
            return
        }
        let start = Date()
        let isIncremental = !parsedLogs.isEmpty || commands.clangFileCount > 0 || !commands.swiftModules.isEmpty
        log(isIncremental ? "解析新的构建日志（\(changed.count) 份）…" : "解析构建日志（\(changed.count) 份）…", level: 0)
        let fresh = BuildLog.parse(logs: changed)
        commands = isIncremental ? fresh.merging(older: commands) : fresh
        for path in changed {
            parsedLogs[path] = BuildLog.modificationDate(of: path)
        }
        // 已不存在的日志不再登记；命令本身保留在缓存里
        parsedLogs = parsedLogs.filter { FileManager.default.fileExists(atPath: $0.key) }
        CommandCache.save(derivedDataPath: buildLog.derivedDataPath, commands: commands, parsedLogs: parsedLogs)
        // 重新构建过：.d 依赖文件随之更新，头文件索引失效，并在后台预先重建
        headerIndex?.invalidate()
        if watchesHeaders, let index = headerIndex {
            let analyzer = headerAnalyzer
            let threshold = maxHeaderDependents
            DispatchQueue.global(qos: .utility).async {
                _ = index.sources(dependingOn: "")
                // 为被大量文件引用的头文件建立内容基线，之后改动时才能知道改了哪些标识符
                analyzer.prime(headers: index.widelyUsedHeaders(threshold: threshold))
            }
        }

        let platforms = Set(commands.swiftModules.map { $0.platform } + commands.allClangCommands.map { $0.platform })
            .filter { $0 != "unknown" }.sorted()
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        log("解析完成（\(elapsed)s）：\(commands.swiftModules.count) 条 Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件，平台：\(platforms.joined(separator: ", "))", level: 1)
        if commands.signingIdentity == nil {
            Diagnostics.shared.log("解析日志", "未从构建日志中取得签名身份（真机注入需要）", level: .debug)
        }
    }

    private func startServer() {
        let server = Server(port: NCProtocol.macPort)
        server.delegate = self
        if server.start() {
            self.server = server
        } else {
            log("TCP 端口 \(NCProtocol.macPort) 监听失败（errno \(errno)），可能已有另一个 NoCompile 在运行", level: 3)
        }
        // 真机 USB 桥接：经 usbmuxd 连接设备上的客户端
        let bridge = DeviceBridge { [weak self] connection in
            self?.accept(connection)
        }
        bridge.start()
        self.deviceBridge = bridge
    }

    /// 在 workQueue 上调用：计算监听目录（工程目录 + 工程外的本地 Pod / 子工程）并（重新）开始监听
    private func startWatching() {
        let projectDir = (projectPath as NSString).deletingLastPathComponent
        // 工程位于"文稿 / 桌面 / 下载"等受保护目录时，未获授权的 App 读不到文件，FSEvents 也会静默失效。
        // 首次访问可能弹出系统授权框，所以放在后台队列执行
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: projectDir)
        } catch {
            log("无法读取工程目录（\(error.localizedDescription)）。若工程在「文稿」「桌面」「下载」中，"
                + "请在 系统设置 → 隐私与安全性 → 文件与文件夹 中允许 NoCompile 访问，"
                + "或在 完全磁盘访问权限 中添加 NoCompile，然后重启 NoCompile", level: 3)
        }
        let roots = [projectDir] + ProjectInfo.externalSourceRoots(projectPath: projectPath)
        guard roots != watchRoots || watcher == nil else {
            return
        }
        watcher?.stop()
        let watcher = FileWatcher(directories: roots) { [weak self] changed in
            self?.handleChangedFiles(changed)
        }
        if !watcher.start() {
            log("文件监听启动失败：\(roots.joined(separator: "、"))", level: 3)
        }
        self.watcher = watcher
        watchRoots = roots
        log("监听目录：\(projectDir)", level: 0)
        for root in roots.dropFirst() {
            log("监听工程外的本地 Pod / 子工程：\(root)", level: 0)
        }
    }

    // MARK: - 文件变更

    private func handleChangedFiles(_ files: [String]) {
        workQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            // 工程结构变化（如 pod install 新增了本地 Pod）：重新计算监听目录
            if files.contains(where: FileWatcher.isProjectStructureFile) {
                Diagnostics.shared.log("监听", "工程结构文件有变化，重新计算监听目录")
                self.startWatching()
            }
            let accepted = files.filter { path in
                !FileWatcher.isProjectStructureFile(path)
                    && !self.excludedKeywords.contains { !$0.isEmpty && path.contains($0) }
            }
            let excluded = files.count - accepted.count
            if excluded > 0 {
                Diagnostics.shared.log("监听", "\(excluded) 个改动被排除规则或工程结构文件过滤", level: .debug)
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

    /// 可接收注入的连接：已握手且与 Mac 端兼容
    private func injectableConnections(skipping files: [String]) -> [ServerConnection] {
        var result: [ServerConnection] = []
        for connection in connections where !connection.clientInfo.isEmpty {
            if let issue = connection.compatibilityIssue {
                let names = files.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                log("跳过 \(connection.displayName)：\(issue)，请重新编译运行 App 后再试（本次改动：\(names)\(files.count > 3 ? " 等" : "")）", level: 2)
                connection.send(NCMessage(type: .status, json: ["message": "NoCompile 版本不一致，请重新编译 App", "state": 2]))
                continue
            }
            result.append(connection)
        }
        return result
    }

    private func inject(files: [String]) {
        guard !isStopped else {
            return
        }
        guard !connections.isEmpty else {
            log("没有已连接的 App，跳过：\(Self.summarize(files))", level: 2)
            return
        }
        let targets = injectableConnections(skipping: files)
        guard !targets.isEmpty else {
            return
        }
        refreshCommandsIfNeeded()

        // 资源文件单独处理：不依赖源码编译命令，构建日志缺失时也能下发图片
        let resources = files.filter { ResourceCompiler.isResource($0) }
        if !resources.isEmpty {
            if watchesResources {
                pushResources(resources.sorted(), to: targets)
            } else {
                Diagnostics.shared.log("资源", "资源热重载已关闭，忽略 \(resources.count) 个资源改动", level: .debug)
            }
        }
        let codeFiles = files.filter { !ResourceCompiler.isResource($0) }
        guard !codeFiles.isEmpty else {
            return
        }
        guard buildLog != nil else {
            log("没有构建日志，无法重编：\(Self.summarize(codeFiles))", level: 2)
            return
        }

        let sources = expandSources(codeFiles)
        guard !sources.isEmpty else {
            return
        }
        if sources.count > maxBatchSourceFiles {
            // 多半是切换了分支：逐个热重载既慢又容易出现新旧代码混用，提示重新编译
            log("一次改动了 \(sources.count) 个源文件（超过 \(maxBatchSourceFiles) 个，可能切换了分支），已跳过热重载，请重新编译运行 App", level: 2)
            targets.forEach { $0.send(NCMessage(type: .status, json: ["message": "改动文件过多，请重新编译 App", "state": 2])) }
            return
        }

        setState(.working)
        var hadError = false
        var succeeded = 0
        var failed = 0
        let ordered = sources.sorted()
        if ordered.count > 1 {
            log("本批改动需重编 \(ordered.count) 个文件：\(Self.summarize(ordered))", level: 0)
        }

        for (index, source) in ordered.enumerated() {
            guard !isStopped else {
                break
            }
            let name = (source as NSString).lastPathComponent
            let progress = ordered.count > 1 ? "（\(index + 1)/\(ordered.count)）" : ""
            notifyStatus("编译中\(progress)：\(name)", state: 1, to: targets)
            // 同一平台、同一架构的多个连接共用一次编译结果
            var builtByPlatform: [String: (result: RecompileResult, elapsed: TimeInterval)] = [:]
            for connection in targets {
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
                                                      platform: platform, codesignIdentity: commands.signingIdentity)
                    built = (result, Date().timeIntervalSince(start))
                    builtByPlatform[buildKey] = built
                }
                if built.result.succeeded, let dylibPath = built.result.dylibPath {
                    succeeded += 1
                    inflight[inflightKey(connection, source)] = (Date(), built.elapsed)
                    sendInject(dylibPath: dylibPath, source: source, isNewFile: built.result.isNewFile, to: connection)
                    let newTag = built.result.isNewFile ? "（新增文件）" : ""
                    log("⚡ \(name)\(newTag) → \(connection.displayName)（编译 \(String(format: "%.2f", built.elapsed))s）", level: 0)
                } else {
                    hadError = true
                    failed += 1
                    let message = built.result.error ?? "重编失败"
                    log("❌ \(name)（\(platform.name)）：\(message)", level: 3)
                    connection.send(NCMessage(type: .status, json: ["message": "编译失败：\(name)", "state": 2]))
                    record(InjectionRecord(file: name, clientName: connection.shortName,
                                           platformTitle: connection.platformTitle, success: false,
                                           duration: built.elapsed, message: message, refreshed: []))
                }
            }
        }
        if ordered.count > 1 {
            log("本批完成：推送 \(succeeded) 个，失败 \(failed) 个", level: failed > 0 ? 2 : 1)
        }
        setState(hadError ? .error("编译失败，详见日志") : .idle)
    }

    /// 把改动的代码文件展开为需要重编的实现文件：头文件按依赖索引找到引用它的实现文件
    private func expandSources(_ codeFiles: [String]) -> Set<String> {
        var sources = Set<String>()
        var headers: [String] = []
        for file in codeFiles {
            if file.hasSuffix(".h") || file.hasSuffix(".hpp") || file.hasSuffix(".pch") {
                headers.append(file)
            } else {
                sources.insert(file)
            }
        }
        guard !headers.isEmpty else {
            return sources
        }
        guard watchesHeaders, let index = headerIndex else {
            Diagnostics.shared.log("头文件", "未开启头文件监听或没有依赖索引，忽略 \(headers.count) 个头文件", level: .debug)
            return sources
        }
        for header in headers {
            let headerName = (header as NSString).lastPathComponent
            let stem = (headerName as NSString).deletingPathExtension
            guard let newText = try? String(contentsOfFile: header, encoding: .utf8) else {
                continue
            }
            // framework 的公开头文件在构建产物里有副本，使用方读的是副本：先同步，再把副本的使用方一并算进来
            let copies = headerAnalyzer.syncProductCopies(of: header, newText: newText, index: index,
                                                          knownCopy: commands.resourceDestinations[ParsedCommands.canonicalPath(header)])
            var dependents = Set(index.sources(dependingOn: header))
            for copy in copies {
                dependents.formUnion(index.sources(dependingOn: copy.path))
            }
            // 与上一版内容对比，得到这次改动涉及的标识符（拿不到旧内容时为 nil）
            // 没有旧内容可对比时，退而用头文件里声明的全部标识符
            let changed = headerAnalyzer.changedIdentifiers(header: header, newText: newText,
                                                            extraOldTexts: copies.map { $0.oldText })
                ?? HeaderChangeAnalyzer.declaredIdentifiers(in: newText)
            // Swift 文件经桥接头 / 模块依赖头文件：同一模块的 Swift 文件都会列为依赖，只取文本里提到改动标识符的
            let swiftDependents = dependents.filter { $0.hasSuffix(".swift") }
            if !swiftDependents.isEmpty {
                let mentionedSwift = HeaderChangeAnalyzer.filter(sources: swiftDependents.sorted(), mentioning: changed)
                if !mentionedSwift.isEmpty, mentionedSwift.count <= maxHeaderDependents {
                    log("头文件 \(headerName) 影响 \(mentionedSwift.count) 个 Swift 文件", level: 0)
                    sources.formUnion(mentionedSwift)
                }
            }
            let sortedDependents = dependents.filter { !$0.hasSuffix(".swift") }.sorted()
            if sortedDependents.isEmpty {
                Diagnostics.shared.log("头文件", "\(headerName) 没有找到依赖它的实现文件（可能只被 Swift 引用或尚未构建过）", level: .debug)
                continue
            }
            if sortedDependents.count <= maxHeaderDependents {
                let added = Set(sortedDependents).subtracting(sources)
                if !added.isEmpty {
                    log("头文件 \(headerName) 影响 \(sortedDependents.count) 个实现文件", level: 0)
                }
                sources.formUnion(sortedDependents)
                continue
            }
            // 公共头文件：先按改动的标识符筛出真正用到它们的文件
            let mentioned = HeaderChangeAnalyzer.filter(sources: sortedDependents, mentioning: changed)
            if mentioned.count <= maxHeaderDependents * 3 {
                sources.formUnion(mentioned)
                log("头文件 \(headerName) 被 \(sortedDependents.count) 个文件引用，其中 \(mentioned.count) 个用到了改动的内容，只重编这些", level: 0)
                continue
            }
            // 筛不出来（拿不到旧内容，或用到的文件仍然很多）：只重编同名实现文件，其余要重新编译 App
            let sameStem = sortedDependents.filter {
                ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension == stem
            }
            sources.formUnion(sameStem)
            let target = sameStem.isEmpty ? "未找到同名实现文件，未重编" : "只重编 \(sameStem.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))"
            log("头文件 \(headerName) 被 \(sortedDependents.count) 个文件引用（超过 \(maxHeaderDependents) 个），\(target)；"
                + "若改动了宏、内联函数或结构体，请重新编译 App", level: 2)
        }
        return sources
    }

    private static func summarize(_ files: [String], limit: Int = 5) -> String {
        let names = files.prefix(limit).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return files.count > limit ? "\(names) 等 \(files.count) 个" : names
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
                Diagnostics.shared.log("发送", "拷贝 dylib 到 App 的 tmp 目录失败（\(error.localizedDescription)），改为随消息传输", level: .warning)
                payload = try? Data(contentsOf: URL(fileURLWithPath: dylibPath))
            }
        } else {
            // 真机：随帧传输 dylib 字节，由客户端写入自己的 tmp 目录
            payload = try? Data(contentsOf: URL(fileURLWithPath: dylibPath))
        }
        if json["localPath"] == nil, payload == nil {
            Diagnostics.shared.log("发送", "读取 dylib 失败：\(dylibPath)", level: .error)
        }
        Diagnostics.shared.log("发送", "\((source as NSString).lastPathComponent) → \(connection.displayName)：\(json["localPath"] as? String ?? "随消息传输 \(payload?.count ?? 0) 字节")", level: .debug)
        connection.send(NCMessage(type: .inject, json: json, data: payload))
    }

    // MARK: - 资源

    /// 整理并下发资源文件。同一平台的多个连接共用一次 ibtool 编译结果
    private func pushResources(_ files: [String], to targets: [ServerConnection]) {
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
            for connection in targets {
                guard let platform = platform(for: connection) else {
                    continue
                }
                let prepared: (result: ResourcePreparation, elapsed: TimeInterval)
                if let cached = preparedByPlatform[platform.name] {
                    prepared = cached
                } else {
                    if file.hasSuffix(".storyboard") || file.hasSuffix(".xib") {
                        notifyStatus("编译中：\(name)", state: 1, to: targets)
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
                    if reason.isEmpty {
                        Diagnostics.shared.log("资源", "\(name) 不是 App 的资源文件，忽略", level: .debug)
                    } else {
                        log("跳过 \(name)（\(connection.displayName)）：\(reason)", level: 0)
                    }
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
                    Diagnostics.shared.log("发送", "读取资源文件失败：\(package.rootDirectory)/\(file)", level: .error)
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

    private func notifyStatus(_ message: String, state: Int, to targets: [ServerConnection]) {
        let json: [String: Any] = ["message": message, "state": state]
        targets.forEach { $0.send(NCMessage(type: .status, json: json)) }
    }

    // MARK: - ServerDelegate / ServerConnectionDelegate

    public func server(_ server: Server, didAccept connection: ServerConnection) {
        accept(connection)
    }

    private func accept(_ connection: ServerConnection) {
        connection.delegate = self
        if isStopped {
            connection.close()
            return
        }
        liveConnectionsLock.lock()
        liveConnections.append(connection)
        liveConnectionsLock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            // 引擎已停止（切换工程 / 重启）后才连上的，直接关闭，让客户端连到新的引擎
            if self.isStopped {
                connection.close()
                return
            }
            self.connections.append(connection)
        }
    }

    public func connection(_ connection: ServerConnection, didReceive message: NCMessage) {
        switch message.type {
        case .hello:
            guard let info = message.json else {
                Diagnostics.shared.log("连接", "收到无内容的握手消息", level: .warning)
                return
            }
            connection.updateClientInfo(info)
            workQueue.async { [weak self] in
                guard let self, !self.isStopped else { return }
                connection.send(NCMessage(type: .helloAck,
                                          json: ["protocol": NCProtocol.version,
                                                 "clientVersion": NCProtocol.clientVersion,
                                                 "config": self.clientConfig]))
                let version = connection.clientVersion ?? "未知"
                self.log("🔌 已连接：\(connection.displayName)，客户端 \(version)", level: 1)
                Diagnostics.shared.log("连接", "握手信息：\(Self.describe(info))")
                self.checkCompatibility(of: connection)
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

    /// 握手后检查客户端是否与 Mac 端匹配；不匹配时提示用户重新编译 App，并不再向它推送注入
    private func checkCompatibility(of connection: ServerConnection) {
        let issue = ClientCompatibility.issue(for: connection.clientInfo, bundledClientDirectory: bundledClientDirectory)
        connection.compatibilityIssue = issue
        guard let issue else {
            return
        }
        log("⚠️ \(connection.displayName)：\(issue)。请在 Xcode 中重新编译并运行 App（必要时先 Clean Build Folder），"
            + "以更新 App 内的 NoCompile 客户端（CocoaPods / SPM / Carthage 接入的请先把 NoCompile 依赖更新到与 Mac 端相同的版本）；"
            + "在此之前不会向它推送热重载", level: 3)
        Diagnostics.shared.log("兼容性", "\(connection.displayName)：\(issue)", level: .error)
        // 旧客户端的浮层只有一行，文案尽量短
        connection.send(NCMessage(type: .status, json: ["message": "NoCompile 版本不一致，请重新编译 App", "state": 2]))
    }

    /// 握手信息转成单行文本（省略路径以外的冗长字段）
    private static func describe(_ info: [String: Any]) -> String {
        return info.keys.sorted().map { "\($0)=\(info[$0] ?? "")" }.joined(separator: ", ")
    }

    /// App 回报注入结果：结合编译耗时生成一条记录（日志已由 App 端转发，这里不再重复打印）
    private func handleInjectResult(_ json: [String: Any], from connection: ServerConnection) {
        let ok = json["ok"] as? Bool ?? false
        let source = (json["sourceFiles"] as? [String])?.first ?? ""
        let refreshed = json["refreshed"] as? [String] ?? []
        let pending = json["pending"] as? [String] ?? []
        let key = inflightKey(connection, source)
        let started = inflight.removeValue(forKey: key)
        let total = started.map { $0.compile + Date().timeIntervalSince($0.start) } ?? 0
        let message = json["message"] as? String ?? ""
        if !ok {
            Diagnostics.shared.log("注入", "\(connection.displayName) 注入 \((source as NSString).lastPathComponent) 失败：\(message)", level: .error)
        }
        var item = InjectionRecord(file: (source as NSString).lastPathComponent,
                                   clientName: connection.shortName,
                                   platformTitle: connection.platformTitle,
                                   success: ok,
                                   duration: total,
                                   message: message,
                                   refreshed: refreshed)
        item.pending = pending
        record(item)
    }

    public func connectionDidClose(_ connection: ServerConnection) {
        liveConnectionsLock.lock()
        liveConnections.removeAll { $0 === connection }
        liveConnectionsLock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.connections.removeAll { $0 === connection }
            // 清理该连接未回报的注入，避免长期运行后无限增长
            let prefix = "\(connection.id)|"
            self.inflight = self.inflight.filter { !$0.key.hasPrefix(prefix) }
            if !connection.clientInfo.isEmpty, !self.isStopped {
                self.log("断开：\(connection.displayName)", level: 2)
            }
            self.notifyClients()
        }
    }

    // MARK: - 诊断

    /// 收集引擎当前状态，用于导出诊断包。在 workQueue 上收集后回到主线程回调；
    /// workQueue 正忙（例如在编译）时会等它空闲，不会阻塞调用方
    public func collectDiagnostics(completion: @escaping (String) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            lines.append("[引擎]")
            lines.append("工程：\(self.projectPath)")
            lines.append("自定义 DerivedData：\(self.customDerivedData ?? "无")")
            lines.append("DerivedData：\(self.buildLog?.derivedDataPath ?? "未找到")")
            lines.append("监听目录：\(self.watchRoots.joined(separator: "、"))")
            lines.append("保存即注入：\(self.injectsOnSave)，头文件：\(self.watchesHeaders)，资源：\(self.watchesResources)")
            lines.append("排除关键字：\(self.excludedKeywords.joined(separator: ", "))")
            lines.append("客户端配置：\(Self.describe(self.clientConfig))")
            lines.append("随附客户端 bundle 目录：\(self.bundledClientDirectory ?? "无")")
            lines.append("已解析日志：")
            for (path, date) in self.parsedLogs.sorted(by: { $0.value > $1.value }) {
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
                lines.append("  \(Diagnostics.shared.timestamp(date))  \(size / 1024)KB  \(path)")
            }
            let platforms = Dictionary(grouping: self.commands.allClangCommands, by: { "\($0.platform)|\($0.arch ?? "?")" })
                .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
            lines.append("Swift 模块命令：\(self.commands.swiftModules.map { "\($0.moduleName ?? "?")(\($0.platform)/\($0.arch ?? "?"))" }.joined(separator: ", "))")
            lines.append("clang 命令（平台|架构=数量）：\(platforms)")
            lines.append("ibtool 命令：\(self.commands.ibtoolCommands.count)，签名身份：\(self.commands.signingIdentity ?? "无")")
            lines.append("待注入：\(self.pendingFiles.count)，等待回报：\(self.inflight.count)")
            lines.append("")
            lines.append("[连接]")
            if self.connections.isEmpty {
                lines.append("无")
            }
            for connection in self.connections {
                lines.append("\(connection.displayName)：\(Self.describe(connection.clientInfo))")
                lines.append("  兼容性：\(connection.compatibilityIssue ?? "正常")")
            }
            DispatchQueue.main.async {
                completion(lines.joined(separator: "\n"))
            }
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
                          machine: connection.machine,
                          clientVersion: connection.clientVersion,
                          compatibilityIssue: connection.compatibilityIssue)
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
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didChangeState: state)
        }
    }

    private func log(_ message: String, level: Int) {
        // 同时写入诊断日志，便于用户导出反馈
        Diagnostics.shared.log("引擎", message, level: Diagnostics.Level(engineLevel: level))
        DispatchQueue.main.async { [weak self] in
            // 已停止的旧引擎（切换工程后）不再往界面输出
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didLog: message, level: level)
        }
    }
}
