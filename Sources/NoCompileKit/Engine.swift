//
//  Engine.swift
//  编排：监听文件 → 重编 → 推送注入。被 CLI 与菜单栏 App 共用。
//
//  线程约定：内部状态只在 workQueue 上读写；所有 delegate 回调都在主线程触发，
//  UI 层可直接操作 AppKit / SwiftUI。
//  公开方法都不会同步等待 workQueue（workQueue 上可能正在执行耗时的编译），
//  因此从主线程调用 stop() 等方法不会卡住界面。
//
//  设备模型：
//  - 只接入当前工程构建的 App；其他工程的 App 保持连接但「搁置」（不展示、不推送），避免它每 2 秒重连刷屏。
//  - 每台设备（某台模拟器 / 真机 / 本机 Mac）只接入一个 App。
//  - 同一时刻只向「当前设备」推送热重载。每次改动都记入本次会话的改动历史；
//    切换设备、或 App 重新运行后连上时，把它还没有的改动补推过去（早于其构建时间的改动已编进 App，不再推）。
//

import Foundation

public enum EngineState: Equatable {
    case idle           // 空闲（绿）
    case working        // 执行中（黄）
    case error(String)  // 出错（红）
}

/// 已接入设备的概要信息（供界面展示）。每台设备一个 App，id 即设备标识
public struct ClientSummary: Identifiable, Equatable {
    /// 设备标识（同一台设备上重新运行 App 后不变）
    public let id: String
    public let connectionID: String
    /// App 名（可执行文件名）
    public let name: String
    public let deviceName: String
    public let systemVersion: String
    public let platform: String         // simulator / device / macosx
    public let platformTitle: String    // 模拟器 / 真机 / macOS
    public let bundleID: String
    public let machine: String
    /// 客户端版本，旧版客户端为 nil
    public var clientVersion: String? = nil
    /// 与 Mac 端不兼容的原因（需要重新编译 App），兼容为 nil
    public var compatibilityIssue: String? = nil
    /// 是否为当前设备（接收热重载）
    public var isActive = false
    /// App 是否在线。当前设备上的 App 退出后仍保留一项（离线），重新运行后自动接上
    public var isOnline = true
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
    /// 目标设备名
    public var deviceName: String = ""
    public let date = Date()
}

public protocol EngineDelegate: AnyObject {
    func engine(_ engine: Engine, didChangeState state: EngineState)
    func engine(_ engine: Engine, didLog entry: EngineLog)
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
    /// 下发给 App 端的偏好设置，变更后立即推送给所有已接入的 App
    public var clientConfig: [String: Any] = [:] {
        didSet {
            let config = clientConfig
            workQueue.async { [weak self] in
                self?.members.values.forEach { $0.send(NCMessage(type: .config, json: ["config": config])) }
            }
        }
    }

    private var buildLog: BuildLog?
    private var commands = ParsedCommands()
    /// 已解析过的日志及其修改时间，只解析新出现 / 有变化的日志
    private var parsedLogs: [String: Date] = [:]
    /// 已读取的构建清单（manifest.json）→ 指纹（修改时间 + 大小）。只在内存里记录：
    /// 清单合成的命令不写入命令缓存（数万条命令会让缓存膨胀到数百 MB），每次启动重新读取清单即可
    private var parsedManifests: [String: String] = [:]
    private var headerIndex: HeaderDependencyIndex?
    private let headerAnalyzer = HeaderChangeAnalyzer()
    private let recompiler: Recompiler
    private let resourceCompiler: ResourceCompiler
    private var server: Server?
    private var deviceBridge: DeviceBridge?
    private var watcher: FileWatcher?
    private var watchRoots: [String] = []

    // MARK: 连接与设备（仅在 workQueue 上访问）

    /// 所有已接受的连接（含尚未握手、被搁置的）
    private var connections: [ServerConnection] = []
    /// 已接入的 App：设备标识 → 连接（每台设备一个）
    private var members: [String: ServerConnection] = [:]
    /// 被搁置的连接：连接标识 → 原因。不展示、不推送，引擎重启（切换工程）时随之断开，客户端会重连到新引擎
    private var parked: [String: String] = [:]
    /// 已提示过的搁置原因，同一个 App 只提示一次
    private var reportedParkings = Set<String>()
    /// 因「还没有构建产物、无法判断归属」而搁置的连接，找到构建日志后重新判断
    private var parkedForMissingBuild = Set<String>()
    /// 当前设备：只向它推送热重载
    private var activeDeviceKey: String?
    /// 当前设备是用户手动选的：App 退出后仍保持选中，重新运行后自动接上；自动选中的设备离线时改选其他在线设备
    private var activeChosenByUser = false
    /// 当前设备离线时界面上展示的信息
    private var activeSnapshot: ClientSummary?
    /// 已对其提示过「当前设备离线」的改动批次，避免每次保存都重复提示
    private var offlineHintShown = false

    // MARK: 改动历史（仅在 workQueue 上访问）

    private struct HistoryEntry {
        let seq: Int
        let date: Date
    }
    /// 本次会话内的改动：需重编的实现文件 / 资源文件 → 最近一次改动
    private var history: [String: HistoryEntry] = [:]
    private var historySeq = 0
    /// 各 App 进程已应用到的改动序号：进程标识 → (文件 → 序号)
    private var applied: [String: [String: Int]] = [:]
    /// 各 App 进程的构建（链接）时间，早于它的改动已编进 App。nil 表示无法确定
    private var buildDates: [String: Date] = [:]

    private var pendingFiles = Set<String>()
    /// 已推送、等待 App 回报结果的注入：键为 "连接标识|源文件"，值为（开始时间, 编译耗时）
    private var inflight: [String: (start: Date, compile: TimeInterval)] = [:]
    private let workQueue = DispatchQueue(label: "com.nocompile.engine")

    /// 所有已接受的连接（加锁访问）：stop() 时不经 workQueue 立即关闭，
    /// 让客户端尽快重连到新引擎，不必等旧引擎手头的编译结束
    private var liveConnections: [ServerConnection] = []
    private let liveConnectionsLock = NSLock()
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
            self.log("🎉 NoCompile 就绪，保存文件即可热重载", level: 1, category: .general)
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
            self.members.removeAll()
            self.parked.removeAll()
        }
    }

    /// 切换当前设备：之后的热重载只推给它，并把它还没有的改动补推过去
    public func selectDevice(_ deviceKey: String) {
        workQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            let changed = self.activeDeviceKey != deviceKey
            self.activeDeviceKey = deviceKey
            self.activeChosenByUser = true
            self.offlineHintShown = false
            guard let connection = self.members[deviceKey] else {
                self.notifyClients()
                return
            }
            self.activeSnapshot = self.summary(of: connection)
            if changed {
                self.log("切换当前设备：\(connection.displayName)", level: 1, category: .device)
            }
            self.notifyClients()
            if connection.compatibilityIssue == nil {
                self.refreshCommandsIfNeeded()
                self.replay(to: connection)
            }
        }
    }

    /// 手动检查改动：立即扫描监听目录，与文件基线比较，把 FSEvents 漏掉的改动交给热重载
    public func checkForChanges() {
        workQueue.async { [weak self] in
            guard let self, let watcher = self.watcher else { return }
            self.log("正在扫描工程目录中的改动…", level: 0, category: .watch)
            watcher.checkNow { [weak self] found in
                guard let self else { return }
                if found == 0 {
                    self.log("没有发现未处理的改动", level: 0, category: .watch)
                } else {
                    self.log("发现 \(found) 个未处理的改动，开始热重载", level: 1, category: .watch)
                }
            }
        }
    }

    // MARK: - 构建日志与命令

    /// 定位构建日志所在的 DerivedData（只定位、不解析）
    private func locateBuildLogIfNeeded() {
        guard buildLog == nil else {
            return
        }
        buildLog = BuildLog.locate(projectPath: projectPath, customDerivedData: customDerivedData)
        guard let buildLog else {
            return
        }
        defer {
            // 此前因找不到构建产物而搁置的 App：现在可以判断归属了
            let waiting = connections.filter { parkedForMissingBuild.contains($0.id) }
            parkedForMissingBuild.removeAll()
            for connection in waiting {
                parked[connection.id] = nil
                handleHello(from: connection, info: connection.clientInfo)
            }
        }
        log("DerivedData：\(buildLog.derivedDataPath)", level: 0, category: .build)
        headerIndex = HeaderDependencyIndex(derivedDataPath: buildLog.derivedDataPath)
        // 载入上次保存的命令：Xcode 清理掉的旧日志里的命令仍然可用，也省去重新解析全部日志
        if let cached = CommandCache.load(derivedDataPath: buildLog.derivedDataPath) {
            commands = cached.commands
            parsedLogs = cached.parsedLogs
            log("载入命令缓存：\(commands.swiftModules.count) 条 Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件",
                level: 0, category: .build)
        }
    }

    /// 定位日志；只解析新出现或有变化的日志，并与已有结果合并（例如先跑真机、再跑模拟器）
    private func refreshCommandsIfNeeded() {
        locateBuildLogIfNeeded()
        guard let buildLog else {
            log("尚未找到构建日志，请先在 Xcode 构建并运行一次", level: 2, category: .build)
            Diagnostics.shared.log("解析日志", "未找到构建日志：\(projectPath)，自定义 DerivedData：\(customDerivedData ?? "无")", level: .warning)
            return
        }
        let logs = buildLog.logFiles()
        let changed = logs.filter { path in
            let date = BuildLog.modificationDate(of: path)
            return parsedLogs[path] != date
        }
        // 构建清单：日志被 Xcode 清理后，清单仍保存着最近一次构建的全部编译任务，用来补全日志里缺的文件
        let manifests = BuildManifest.manifestFiles(derivedDataPath: buildLog.derivedDataPath)
        let changedManifests = manifests.filter { parsedManifests[$0] != BuildManifest.fingerprint(of: $0) }
        guard !changed.isEmpty || !changedManifests.isEmpty else {
            return
        }
        let start = Date()
        if !changed.isEmpty {
            let isIncremental = !parsedLogs.isEmpty || commands.clangFileCount > 0 || !commands.swiftModules.isEmpty
            log(isIncremental ? "解析新的构建日志（\(changed.count) 份）…" : "解析构建日志（\(changed.count) 份）…", level: 0, category: .build)
            let fresh = BuildLog.parse(logs: changed)
            commands = isIncremental ? fresh.merging(older: commands) : fresh
            for path in changed {
                parsedLogs[path] = BuildLog.modificationDate(of: path)
            }
            // 已不存在的日志不再登记；命令本身保留在缓存里
            parsedLogs = parsedLogs.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        if !changedManifests.isEmpty {
            fillCommandsFromManifests(changedManifests, allManifests: manifests)
        }
        CommandCache.save(derivedDataPath: buildLog.derivedDataPath, commands: commands.droppingSynthesized(), parsedLogs: parsedLogs)
        // 重新构建过：.d 依赖文件随之更新，头文件索引失效，并在后台预先重建
        headerIndex?.invalidate()
        if watchesHeaders, let index = headerIndex {
            let analyzer = headerAnalyzer
            let threshold = maxHeaderDependents
            let scheduled = Date()
            DispatchQueue.global(qos: .utility).async {
                _ = index.sources(dependingOn: "")
                // 为被大量文件引用的头文件建立内容基线，之后改动时才能知道改了哪些标识符
                analyzer.prime(headers: index.widelyUsedHeaders(threshold: threshold), modifiedBefore: scheduled)
            }
        }

        let platforms = Set(commands.swiftModules.map { $0.platform } + commands.allClangCommands.map { $0.platform })
            .filter { $0 != "unknown" }.sorted()
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        log("解析完成（\(elapsed)s）：\(commands.swiftModules.count) 条 Swift 模块命令，\(commands.clangFileCount) 个 C/ObjC/C++ 文件，平台：\(platforms.joined(separator: ", "))",
            level: 0, category: .build)
        if commands.signingIdentity == nil {
            Diagnostics.shared.log("解析日志", "未从构建日志中取得签名身份（真机注入需要）", level: .debug)
        }
    }

    /// 读取构建清单，给日志里没有命令的 C/ObjC/C++ 文件合成命令。
    /// 清单从新到旧依次处理，同一文件以较新的清单为准；日志里的真实命令始终优先
    private func fillCommandsFromManifests(_ changedManifests: [String], allManifests: [String]) {
        let start = Date()
        let before = commands.clangFileCount
        let workingDirectory = (projectPath as NSString).deletingLastPathComponent
        var tasks: [BuildManifest.CompileTask] = []
        for path in allManifests where changedManifests.contains(path) {
            let before = BuildManifest.fingerprint(of: path)
            let parsed = BuildManifest.parseCompileTasks(manifestPath: path)
            let after = BuildManifest.fingerprint(of: path)
            let name = (path as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? path
            Diagnostics.shared.log("构建清单", "\(name)：\(parsed.tasks.count) 个 CompileC 任务\(parsed.complete ? "" : "（未读到结尾）")", level: .info)
            tasks.append(contentsOf: parsed.tasks)
            // 解析期间清单被 Xcode 改写（正在构建）：不登记，下次再读完整版本
            if before == after {
                parsedManifests[path] = after
            }
        }
        let filled = BuildManifest.fill(commands, with: tasks, fallbackWorkingDirectory: workingDirectory)
        commands = filled.commands
        // 已不存在的清单不再登记
        parsedManifests = parsedManifests.filter { FileManager.default.fileExists(atPath: $0.key) }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        log("读取构建清单（\(changedManifests.count) 份，\(elapsed)s）：补全 \(filled.added) 个文件的编译命令，"
            + "C/ObjC/C++ 文件 \(before) → \(commands.clangFileCount)", level: 0, category: .build)
    }

    private func startServer() {
        let server = Server(port: NCProtocol.macPort)
        server.delegate = self
        if server.start() {
            self.server = server
        } else {
            log("TCP 端口 \(NCProtocol.macPort) 监听失败（errno \(errno)），可能已有另一个 NoCompile 在运行", level: 3, category: .connection)
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
                + "或在 完全磁盘访问权限 中添加 NoCompile，然后重启 NoCompile", level: 3, category: .watch)
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
            log("FSEvents 文件监听启动失败，保存后请点「检查改动」或按快捷键手动触发：\(roots.joined(separator: "、"))", level: 3, category: .watch)
        }
        self.watcher = watcher
        watchRoots = roots
        log("监听目录：\(projectDir)", level: 0, category: .watch)
        for root in roots.dropFirst() {
            log("监听工程外的本地 Pod / 子工程：\(root)", level: 0, category: .watch)
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
                self.process(accepted)
            } else {
                self.pendingFiles.formUnion(accepted)
                self.notifyPendingFiles()
                self.log("已记录 \(accepted.count) 个改动，等待手动注入：\(Self.summarize(accepted))", level: 0, category: .watch)
            }
        }
    }

    /// 手动注入指定文件
    public func triggerInjection(files: [String]) {
        workQueue.async { [weak self] in
            self?.process(files)
        }
    }

    /// 手动注入累积的待处理改动（"保存即注入"关闭时使用）
    public func triggerPendingInjection() {
        workQueue.async { [weak self] in
            guard let self, !self.pendingFiles.isEmpty else { return }
            let files = Array(self.pendingFiles)
            self.pendingFiles.removeAll()
            self.notifyPendingFiles()
            self.process(files)
        }
    }

    /// 处理一批改动：展开为需要重编的文件，记入改动历史，再推送给当前设备
    private func process(_ files: [String]) {
        guard !isStopped else {
            return
        }
        refreshCommandsIfNeeded()
        var resources: [String] = []
        if watchesResources {
            resources = files.filter { ResourceCompiler.isResource($0) }.sorted()
        } else if files.contains(where: { ResourceCompiler.isResource($0) }) {
            Diagnostics.shared.log("资源", "资源热重载已关闭，忽略资源改动", level: .debug)
        }
        let codeFiles = files.filter { !ResourceCompiler.isResource($0) }
        var sources: [String] = []
        if !codeFiles.isEmpty {
            if buildLog == nil {
                log("没有构建日志，无法重编：\(Self.summarize(codeFiles))", level: 2, category: .compile)
            } else {
                sources = expandSources(codeFiles).sorted()
            }
        }
        guard !sources.isEmpty || !resources.isEmpty else {
            return
        }
        if sources.count > maxBatchSourceFiles {
            // 多半是切换了分支：逐个热重载既慢又容易出现新旧代码混用，提示重新编译
            log("一次改动了 \(sources.count) 个源文件（超过 \(maxBatchSourceFiles) 个，可能切换了分支），已跳过热重载，请重新编译运行 App",
                level: 2, category: .compile)
            activeTarget(quiet: true)?.send(NCMessage(type: .status, json: ["message": "改动文件过多，请重新编译 App", "state": 2]))
            return
        }
        recordHistory(sources + resources)
        guard let target = activeTarget(quiet: false, files: sources + resources) else {
            return
        }
        offlineHintShown = false
        push(sources: sources, resources: resources, to: target)
    }

    /// 记入改动历史
    private func recordHistory(_ files: [String]) {
        let now = Date()
        for file in files {
            historySeq += 1
            history[file] = HistoryEntry(seq: historySeq, date: now)
        }
    }

    /// 当前设备上可接收注入的连接。没有时按情况提示（改动已记入历史，之后会补推）
    private func activeTarget(quiet: Bool, files: [String] = []) -> ServerConnection? {
        if let key = activeDeviceKey, let connection = members[key] {
            if let issue = connection.compatibilityIssue {
                if !quiet {
                    log("跳过 \(connection.displayName)：\(issue)，请重新编译运行 App 后再试（本次改动：\(Self.summarize(files))）",
                        level: 2, category: .inject)
                    connection.send(NCMessage(type: .status, json: ["message": "NoCompile 版本不一致，请重新编译 App", "state": 2]))
                }
                return nil
            }
            return connection
        }
        guard !quiet, !offlineHintShown else {
            return nil
        }
        offlineHintShown = true
        if members.isEmpty {
            log("没有已连接的 App，改动已记录（\(Self.summarize(files))），App 运行后会自动补推", level: 2, category: .device)
        } else if let snapshot = activeSnapshot {
            let others = members.values.map { $0.deviceLabel }.sorted().joined(separator: "、")
            log("当前设备 \(snapshot.deviceName) 未连接，改动已记录，重新运行后自动补推；也可在左侧切换到：\(others)",
                level: 2, category: .device)
        }
        return nil
    }

    /// 编译并推送一批文件给指定连接，成功推送的记为已应用
    private func push(sources: [String], resources: [String], to connection: ServerConnection) {
        if !resources.isEmpty {
            pushResources(resources, to: connection)
        }
        guard !sources.isEmpty, let platform = platform(for: connection) else {
            return
        }
        setState(.working)
        var hadError = false
        var succeeded = 0
        var failed = 0
        if sources.count > 1 {
            log("本批需重编 \(sources.count) 个文件：\(Self.summarize(sources))", level: 0, category: .compile)
        }
        for (index, source) in sources.enumerated() {
            guard !isStopped else {
                break
            }
            let name = (source as NSString).lastPathComponent
            // 文件只属于其他平台的目标（如 macOS 源文件遇到 iOS 客户端）：该客户端无需处理，静默跳过
            if commands.isOnlyBuiltForOtherPlatforms(source, platform: platform.name) {
                Diagnostics.shared.log("重编", "\(name) 不属于 \(platform.name) 平台的目标，跳过 \(connection.displayName)", level: .debug)
                markApplied(source, for: connection)
                continue
            }
            let progress = sources.count > 1 ? "（\(index + 1)/\(sources.count)）" : ""
            notifyStatus("编译中\(progress)：\(name)", state: 1, to: connection)
            let start = Date()
            let result = recompiler.recompile(sourceFile: source, commands: commands,
                                              platform: platform, codesignIdentity: commands.signingIdentity)
            let elapsed = Date().timeIntervalSince(start)
            if result.succeeded, let dylibPath = result.dylibPath {
                succeeded += 1
                inflight[inflightKey(connection, source)] = (Date(), elapsed)
                sendInject(dylibPath: dylibPath, source: source, isNewFile: result.isNewFile, to: connection)
                markApplied(source, for: connection)
                let newTag = result.isNewFile ? "（新增文件）" : ""
                log("\(name)\(newTag) 编译完成（\(String(format: "%.2f", elapsed))s），推送到 \(connection.deviceLabel)", level: 0, category: .compile)
            } else {
                hadError = true
                failed += 1
                let message = result.error ?? "重编失败"
                log("\(name) 编译失败（\(platform.name)）：\(message)", level: 3, category: .compile)
                connection.send(NCMessage(type: .status, json: ["message": "编译失败：\(name)", "state": 2]))
                var item = InjectionRecord(file: name, clientName: connection.shortName,
                                           platformTitle: connection.platformTitle, success: false,
                                           duration: elapsed, message: message, refreshed: [])
                item.deviceName = connection.deviceName
                record(item)
            }
        }
        if sources.count > 1 {
            log("本批完成：推送 \(succeeded) 个，失败 \(failed) 个", level: failed > 0 ? 2 : 1, category: .compile)
        }
        setState(hadError ? .error("编译失败，详见日志") : .idle)
    }

    private func markApplied(_ file: String, for connection: ServerConnection) {
        guard let entry = history[file] else {
            return
        }
        applied[connection.processKey, default: [:]][file] = entry.seq
    }

    /// 把连接还没有的改动补推过去：跳过已推送过的，以及早于 App 构建时间（已编进 App）的改动
    private func replay(to connection: ServerConnection) {
        guard !history.isEmpty else {
            return
        }
        let done = applied[connection.processKey] ?? [:]
        let buildDate = buildDates[connection.processKey]
        let due = history
            .filter { file, entry in
                (done[file] ?? 0) < entry.seq && (buildDate == nil || entry.date > buildDate!)
            }
            .sorted { $0.value.seq < $1.value.seq }
            .map { $0.key }
        guard !due.isEmpty else {
            return
        }
        let resources = due.filter { ResourceCompiler.isResource($0) }
        let sources = due.filter { !ResourceCompiler.isResource($0) }
        if sources.count > maxBatchSourceFiles {
            log("\(connection.displayName) 缺少 \(sources.count) 个改动（超过 \(maxBatchSourceFiles) 个），不再逐个补推，请重新编译运行 App",
                level: 2, category: .device)
            return
        }
        log("补推 \(due.count) 个改动到 \(connection.displayName)：\(Self.summarize(due))", level: 0, category: .device)
        push(sources: sources, resources: resources, to: connection)
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
                    log("头文件 \(headerName) 影响 \(mentionedSwift.count) 个 Swift 文件", level: 0, category: .compile)
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
                    log("头文件 \(headerName) 影响 \(sortedDependents.count) 个实现文件", level: 0, category: .compile)
                }
                sources.formUnion(sortedDependents)
                continue
            }
            // 公共头文件：先按改动的标识符筛出真正用到它们的文件
            let mentioned = HeaderChangeAnalyzer.filter(sources: sortedDependents, mentioning: changed)
            if mentioned.count <= maxHeaderDependents * 3 {
                sources.formUnion(mentioned)
                log("头文件 \(headerName) 被 \(sortedDependents.count) 个文件引用，其中 \(mentioned.count) 个用到了改动的内容，只重编这些",
                    level: 0, category: .compile)
                continue
            }
            // 筛不出来（拿不到旧内容，或用到的文件仍然很多）：只重编同名实现文件，其余要重新编译 App
            let sameStem = sortedDependents.filter {
                ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension == stem
            }
            sources.formUnion(sameStem)
            let target = sameStem.isEmpty ? "未找到同名实现文件，未重编" : "只重编 \(sameStem.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))"
            log("头文件 \(headerName) 被 \(sortedDependents.count) 个文件引用（超过 \(maxHeaderDependents) 个），\(target)；"
                + "若改动了宏、内联函数或结构体，请重新编译 App", level: 2, category: .compile)
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

    /// 整理并下发资源文件
    private func pushResources(_ files: [String], to connection: ServerConnection) {
        guard let platform = platform(for: connection) else {
            return
        }
        setState(.working)
        var hadError = false
        var handledKeys = Set<String>()
        for file in files {
            // 一次保存了同一图片集的多个文件（如 @2x、@3x）时只下发一次
            guard handledKeys.insert(ResourceCompiler.batchKey(for: file)).inserted else {
                markApplied(file, for: connection)
                continue
            }
            let name = (file as NSString).lastPathComponent
            if file.hasSuffix(".storyboard") || file.hasSuffix(".xib") {
                notifyStatus("编译中：\(name)", state: 1, to: connection)
            }
            let start = Date()
            let prepared = resourceCompiler.prepare(file: file, commands: commands, platform: platform)
            let elapsed = Date().timeIntervalSince(start)
            switch prepared {
            case .ready(let package):
                inflight[inflightKey(connection, file)] = (Date(), elapsed)
                sendResource(package, to: connection)
                markApplied(file, for: connection)
                log("\(name) 已整理（\(String(format: "%.2f", elapsed))s），推送到 \(connection.deviceLabel)", level: 0, category: .resource)
            case .skipped(let reason):
                markApplied(file, for: connection)
                if reason.isEmpty {
                    Diagnostics.shared.log("资源", "\(name) 不是 App 的资源文件，忽略", level: .debug)
                } else {
                    log("跳过 \(name)：\(reason)", level: 0, category: .resource)
                }
            case .failed(let error):
                hadError = true
                log("\(name) 处理失败：\(error)", level: 3, category: .resource)
                connection.send(NCMessage(type: .status, json: ["message": "资源处理失败：\(name)", "state": 2]))
                var item = InjectionRecord(file: name, clientName: connection.shortName,
                                           platformTitle: connection.platformTitle, success: false,
                                           duration: elapsed, message: error, refreshed: [])
                item.deviceName = connection.deviceName
                record(item)
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
            log("未知的客户端平台：\(connection.platformName)", level: 3, category: .connection)
            return nil
        }
        guard let sdkPath = ProjectInfo.sdkPath(for: name) else {
            log("无法定位 \(name) SDK", level: 3, category: .compile)
            return nil
        }
        // 模拟器 / macOS 的 machine 即 uname 架构（arm64 / x86_64）；真机是机型标识，统一按 arm64
        let arch = connection.machine.hasPrefix("x86") ? "x86_64" : "arm64"
        return Platform(name: name, sdkPath: sdkPath, arch: arch, isSimulator: isSimulator, isDevice: isDevice)
    }

    private func notifyStatus(_ message: String, state: Int, to connection: ServerConnection) {
        connection.send(NCMessage(type: .status, json: ["message": message, "state": state]))
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
                self.handleHello(from: connection, info: info)
            }
        case .log:
            guard let msg = message.json?["message"] as? String else {
                return
            }
            let level = message.json?["level"] as? Int ?? 0
            workQueue.async { [weak self] in
                // 被搁置的 App（其他工程 / 设备上的第二个 App）的日志不展示
                guard let self, self.isMember(connection) else { return }
                self.emit(EngineLog(level: level, category: .app, message: msg, source: connection.displayName))
            }
        case .injectResult, .resourceResult:
            let json = message.json ?? [:]
            let isResource = message.type == .resourceResult
            workQueue.async { [weak self] in
                guard let self, self.isMember(connection) else { return }
                self.handleInjectResult(json, from: connection, isResource: isResource)
            }
        default:
            break
        }
    }

    private func isMember(_ connection: ServerConnection) -> Bool {
        return members[connection.deviceKey] === connection
    }

    /// 握手：判断是否属于当前工程、占用哪台设备，接入后按需补推改动
    private func handleHello(from connection: ServerConnection, info: [String: Any]) {
        // 先定位 DerivedData：工程打开后才第一次构建运行时，此前还没有构建日志
        locateBuildLogIfNeeded()
        let product: AppProduct?
        switch classify(connection) {
        case .foreign(let reason):
            park(connection, reason: reason)
            return
        case .member(let matched):
            product = matched
        }
        let key = connection.deviceKey
        if let existing = members[key], existing !== connection {
            if existing.bundleID == connection.bundleID && existing.processKey != connection.processKey {
                // 同一个 App 在这台设备上重新运行了：旧连接多半已失效，换成新的
                Diagnostics.shared.log("连接", "\(connection.displayName) 重新连接，替换旧连接")
                members[key] = nil
                existing.close()
            } else {
                // 同一进程的第二条连接（如 USB 与 Wi-Fi 同时连上），或同一设备上的另一个 App：每台设备只接入一个
                let reason = existing.bundleID == connection.bundleID
                    ? "同一个 App 进程已有连接"
                    : "\(connection.deviceLabel) 上已接入 \(existing.shortName)，每台设备只接入一个 App"
                park(connection, reason: reason)
                return
            }
        }
        members[key] = connection
        if let product {
            buildDates[connection.processKey] = product.linkDate
        }
        connection.send(NCMessage(type: .helloAck,
                                  json: ["protocol": NCProtocol.version,
                                         "clientVersion": NCProtocol.clientVersion,
                                         "clientRevision": NCProtocol.clientRevision,
                                         "config": clientConfig]))
        let version = connection.clientVersion ?? "未知"
        log("已连接：\(connection.displayName)，客户端 \(version)", level: 1, category: .connection)
        Diagnostics.shared.log("连接", "握手信息：\(Self.describe(info))")
        checkCompatibility(of: connection)

        // 还没有当前设备，或自动选中的设备已离线：选中这台
        if activeDeviceKey == nil || (!activeChosenByUser && members[activeDeviceKey ?? ""] == nil) {
            activeDeviceKey = key
            activeChosenByUser = false
            if members.count > 1 {
                log("当前设备：\(connection.deviceLabel)", level: 0, category: .device)
            }
        }
        if activeDeviceKey == key {
            activeSnapshot = summary(of: connection)
            offlineHintShown = false
        }
        notifyClients()
        refreshCommandsIfNeeded()
        if activeDeviceKey == key, connection.compatibilityIssue == nil {
            replay(to: connection)
        }
    }

    private enum Membership {
        /// 属于当前工程；能确定对应的构建产物时附带它（用于推算构建时间）
        case member(AppProduct?)
        case foreign(String)
    }

    /// 客户端的 App 是否由当前打开的工程构建（在 workQueue 上调用）
    private func classify(_ connection: ServerConnection) -> Membership {
        let bundleID = connection.bundleID
        guard !bundleID.isEmpty else {
            return .foreign("没有 bundleID")
        }
        guard let derivedDataPath = buildLog?.derivedDataPath else {
            parkedForMissingBuild.insert(connection.id)
            return .foreign("尚未找到当前工程的构建产物，无法确认它属于当前工程（构建后会自动重新判断）")
        }
        // macOS App 直接从 DerivedData 运行，看路径即可
        let bundlePath = connection.clientInfo["bundlePath"] as? String ?? ""
        if connection.platformName == "macosx", bundlePath.contains("/DerivedData/") || bundlePath.contains("/Build/Products/") {
            let ours = (derivedDataPath as NSString).standardizingPath + "/"
            if !(bundlePath as NSString).standardizingPath.hasPrefix(ours) {
                return .foreign("它从另一个工程的构建目录运行（\(bundlePath)）")
            }
        }
        let products = AppProducts.products(derivedDataPath: derivedDataPath).filter { $0.bundleID == bundleID }
        guard !products.isEmpty else {
            return .foreign("它不是当前工程构建的 App（\(bundleID) 不在当前工程的构建产物中）")
        }
        let uuids = connection.imageUUIDs
        if let matched = products.first(where: { !$0.uuids.isDisjoint(with: uuids) }) {
            return .member(matched)
        }
        // UUID 对不上：可能是本工程较早的构建，也可能是另一份同名工程（bundleID 相同）的构建
        let appName = (bundlePath as NSString).lastPathComponent
        if let other = AppProducts.otherProject(owning: uuids, appName: appName, excluding: derivedDataPath) {
            return .foreign("它由另一个工程构建（\(other)）")
        }
        return .member(nil)
    }

    /// 搁置连接：保持连接但不展示、不推送。同一原因对同一个 App 只提示一次
    private func park(_ connection: ServerConnection, reason: String) {
        parked[connection.id] = reason
        let key = "\(connection.bundleID)|\(connection.deviceKey)|\(reason)"
        if reportedParkings.insert(key).inserted {
            log("忽略 \(connection.displayName)：\(reason)", level: 0, category: .connection)
        }
        Diagnostics.shared.log("连接", "搁置 \(connection.displayName)：\(reason)，bundlePath=\(connection.clientInfo["bundlePath"] as? String ?? "")")
    }

    /// 握手后检查客户端是否与 Mac 端匹配；不匹配时提示用户重新编译 App，并不再向它推送注入
    private func checkCompatibility(of connection: ServerConnection) {
        let issue = ClientCompatibility.issue(for: connection.clientInfo)
        connection.compatibilityIssue = issue
        guard let issue else {
            return
        }
        log("\(connection.displayName)：\(issue)。请在 Xcode 中重新编译并运行 App（必要时先 Clean Build Folder），"
            + "以更新 App 内的 NoCompile 客户端（CocoaPods / SPM / Carthage 接入的请先把 NoCompile 依赖更新到与 Mac 端相同的版本）；"
            + "在此之前不会向它推送热重载", level: 3, category: .connection)
        Diagnostics.shared.log("兼容性", "\(connection.displayName)：\(issue)", level: .error)
        // 旧客户端的浮层只有一行，文案尽量短
        connection.send(NCMessage(type: .status, json: ["message": "NoCompile 版本不一致，请重新编译 App", "state": 2]))
    }

    /// 握手信息转成单行文本
    private static func describe(_ info: [String: Any]) -> String {
        return info.keys.sorted().map { "\($0)=\(info[$0] ?? "")" }.joined(separator: ", ")
    }

    /// App 回报注入结果：结合编译耗时生成一条记录与一行日志
    private func handleInjectResult(_ json: [String: Any], from connection: ServerConnection, isResource: Bool) {
        let ok = json["ok"] as? Bool ?? false
        let source = (json["sourceFiles"] as? [String])?.first ?? ""
        let refreshed = json["refreshed"] as? [String] ?? []
        let pending = json["pending"] as? [String] ?? []
        let key = inflightKey(connection, source)
        let started = inflight.removeValue(forKey: key)
        let total = started.map { $0.compile + Date().timeIntervalSince($0.start) } ?? 0
        let message = json["message"] as? String ?? ""
        let name = (source as NSString).lastPathComponent
        let category: LogCategory = isResource ? .resource : .inject
        if ok {
            var details = [connection.deviceLabel]
            if total > 0 {
                details.append(String(format: "共 %.2fs", total))
            }
            if let summary = json["summary"] as? String, !summary.isEmpty {
                details.append(summary)
            }
            if !refreshed.isEmpty {
                details.append("已刷新 \(refreshed.joined(separator: "、"))")
            }
            var text = "\(name) 已生效（\(details.joined(separator: "，"))）"
            if !pending.isEmpty {
                text += "；退出 \(pending.joined(separator: "、")) 后重新进入即可看到改动"
            }
            log(text, level: 1, category: category)
        } else {
            log("\(name) 注入失败（\(connection.deviceLabel)）：\(message)", level: 3, category: category)
            Diagnostics.shared.log("注入", "\(connection.displayName) 注入 \(name) 失败：\(message)", level: .error)
        }
        var item = InjectionRecord(file: name,
                                   clientName: connection.shortName,
                                   platformTitle: connection.platformTitle,
                                   success: ok,
                                   duration: total,
                                   message: message,
                                   refreshed: refreshed)
        item.pending = pending
        item.deviceName = connection.deviceName
        record(item)
    }

    public func connectionDidClose(_ connection: ServerConnection) {
        liveConnectionsLock.lock()
        liveConnections.removeAll { $0 === connection }
        liveConnectionsLock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.connections.removeAll { $0 === connection }
            self.parked[connection.id] = nil
            self.parkedForMissingBuild.remove(connection.id)
            // 清理该连接未回报的注入，避免长期运行后无限增长
            let prefix = "\(connection.id)|"
            self.inflight = self.inflight.filter { !$0.key.hasPrefix(prefix) }
            let key = connection.deviceKey
            guard self.members[key] === connection else {
                return
            }
            self.members[key] = nil
            // 进程的其他连接都没了才清理它的补推记录
            if !self.members.values.contains(where: { $0.processKey == connection.processKey }) {
                self.applied[connection.processKey] = nil
                self.buildDates[connection.processKey] = nil
            }
            if !self.isStopped {
                let isActive = self.activeDeviceKey == key
                self.log("断开：\(connection.displayName)\(isActive ? "（当前设备，重新运行后会自动接上并补推改动）" : "")",
                         level: 2, category: .connection)
                if isActive && !self.activeChosenByUser, let next = self.members.values.sorted(by: { $0.connectedAt > $1.connectedAt }).first {
                    // 自动选中的设备离线了：改用其他在线设备
                    self.activeDeviceKey = next.deviceKey
                    self.activeSnapshot = self.summary(of: next)
                    self.log("当前设备改为：\(next.deviceLabel)", level: 0, category: .device)
                    if next.compatibilityIssue == nil {
                        self.replay(to: next)
                    }
                }
                self.rehomeParkedConnections(on: key)
            }
            self.notifyClients()
        }
    }

    /// 设备上的 App 断开后，该设备上之前因「已有 App」被搁置的连接重新握手一次
    private func rehomeParkedConnections(on deviceKey: String) {
        let candidates = connections.filter { parked[$0.id] != nil && $0.deviceKey == deviceKey && !$0.clientInfo.isEmpty }
        for candidate in candidates {
            parked[candidate.id] = nil
            handleHello(from: candidate, info: candidate.clientInfo)
            if members[deviceKey] != nil {
                break
            }
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
            lines.append("待注入：\(self.pendingFiles.count)，等待回报：\(self.inflight.count)，改动历史：\(self.history.count)")
            lines.append("")
            lines.append("[连接]")
            lines.append("当前设备：\(self.activeDeviceKey ?? "无")\(self.activeChosenByUser ? "（手动选择）" : "")")
            if self.connections.isEmpty {
                lines.append("无")
            }
            for connection in self.connections {
                let role = self.isMember(connection) ? "已接入" : (self.parked[connection.id].map { "搁置：\($0)" } ?? "未握手")
                lines.append("\(connection.displayName)［\(role)］：\(Self.describe(connection.clientInfo))")
                lines.append("  设备：\(connection.deviceKey)，兼容性：\(connection.compatibilityIssue ?? "正常")，"
                    + "构建时间：\(self.buildDates[connection.processKey].map { Diagnostics.shared.timestamp($0) } ?? "未知")")
            }
            DispatchQueue.main.async {
                completion(lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - 回调（统一切到主线程）

    private func summary(of connection: ServerConnection) -> ClientSummary {
        var summary = ClientSummary(id: connection.deviceKey,
                                    connectionID: connection.id,
                                    name: connection.shortName,
                                    deviceName: connection.deviceName,
                                    systemVersion: connection.systemVersion,
                                    platform: connection.platformName,
                                    platformTitle: connection.platformTitle,
                                    bundleID: connection.bundleID,
                                    machine: connection.machine)
        summary.clientVersion = connection.clientVersion
        summary.compatibilityIssue = connection.compatibilityIssue
        return summary
    }

    private func notifyClients() {
        var summaries = members.values.sorted { $0.connectedAt < $1.connectedAt }.map { connection -> ClientSummary in
            var item = summary(of: connection)
            item.isActive = connection.deviceKey == activeDeviceKey
            return item
        }
        // 手动选中的当前设备离线时仍列出，提示重新运行后会自动接上
        if let key = activeDeviceKey, members[key] == nil, activeChosenByUser, var snapshot = activeSnapshot {
            snapshot.isActive = true
            snapshot.isOnline = false
            summaries.insert(snapshot, at: 0)
        }
        let onlineCount = members.count
        DispatchQueue.main.async { [weak self] in
            // 已停止的旧引擎（切换工程后）迟到的回调不能覆盖新引擎的状态
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didUpdateClientCount: onlineCount)
            self.delegate?.engine(self, didUpdateClients: summaries)
        }
    }

    private func notifyPendingFiles() {
        let files = pendingFiles.sorted()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didUpdatePendingFiles: files)
        }
    }

    private func record(_ record: InjectionRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didRecord: record)
        }
    }

    private func setState(_ state: EngineState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didChangeState: state)
        }
    }

    private func log(_ message: String, level: Int, category: LogCategory) {
        emit(EngineLog(level: level, category: category, message: message))
    }

    private func emit(_ entry: EngineLog) {
        // 同时写入诊断日志，便于用户导出反馈
        Diagnostics.shared.log(entry.category.title, (entry.source.map { "[\($0)] " } ?? "") + entry.message,
                               level: Diagnostics.Level(engineLevel: entry.level))
        DispatchQueue.main.async { [weak self] in
            // 已停止的旧引擎（切换工程后）不再往界面输出
            guard let self, !self.isStopped else { return }
            self.delegate?.engine(self, didLog: entry)
        }
    }
}
