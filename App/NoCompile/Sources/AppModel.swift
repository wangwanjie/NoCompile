//
//  AppModel.swift
//  界面状态：持有引擎，汇总状态、连接、注入记录与日志
//

import AppKit
import Combine
import UniformTypeIdentifiers
import NoCompileKit
import UserNotifications

/// 一行日志
struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let level: Int      // 0 信息 / 1 成功 / 2 警告 / 3 错误
    let category: LogCategory
    /// App 端日志的来源（App 名 @ 设备）
    let source: String?
    let text: String
}

final class AppModel: ObservableObject, EngineDelegate {

    static let shared = AppModel()

    @Published private(set) var state: EngineState = .idle
    /// 已接入的设备（每台设备一个 App），含离线的当前设备
    @Published private(set) var clients: [ClientSummary] = []
    @Published private(set) var records: [InjectionRecord] = []
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var pendingFiles: [String] = []
    @Published private(set) var isRunning = false
    /// 正在导出诊断包
    @Published private(set) var isExportingDiagnostics = false

    let preferences = Preferences.shared
    private var engine: Engine?
    private var cancellables = Set<AnyCancellable>()

    /// 日志文件：~/Library/Logs/NoCompile/NoCompile.log，便于排查与反馈
    let logFileURL: URL = Diagnostics.shared.directory.appendingPathComponent("NoCompile.log")

    /// 控制台日志文件的写入器：后台串行写入，主线程不做文件 IO
    private lazy var logWriter: LogFileWriter = {
        // 每次启动重新记录；上一次的日志保留为 NoCompile.previous.log（卡死后强制退出，重启时仍能导出上次的日志）
        let fm = FileManager.default
        let previous = Diagnostics.shared.directory.appendingPathComponent("NoCompile.previous.log")
        if fm.fileExists(atPath: logFileURL.path) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: logFileURL, to: previous)
        }
        // 长时间运行、App 日志转发密集时文件会持续变大：超过 50MB 轮转为 NoCompile.1.log
        return LogFileWriter(url: logFileURL, truncate: true, maxBytes: 50 * 1024 * 1024)
    }()

    /// 尚未刷到界面的日志：日志密集时合并成一次界面更新，避免逐行刷新拖慢主线程
    private var bufferedLogs: [LogLine] = []
    private var logFlushScheduled = false
    /// 已提示过版本不一致的连接
    private var notifiedIncompatibleClients = Set<String>()
    /// 界面上单行日志的最大长度，超出部分只写入日志文件（超长文本排版会拖慢主线程）
    private let maxDisplayedLogLength = 4000

    private init() {
        observePreferences()
    }

    // MARK: - 派生属性

    var projectName: String {
        let path = preferences.projectPath
        return path.isEmpty ? "未选择工程" : (path as NSString).lastPathComponent
    }

    var hasProject: Bool {
        return !preferences.projectPath.isEmpty
    }

    /// 当前设备（接收热重载）
    var activeClient: ClientSummary? {
        return clients.first { $0.isActive }
    }

    var successCount: Int { records.filter { $0.success }.count }
    var failureCount: Int { records.filter { !$0.success }.count }
    var averageDuration: TimeInterval {
        let succeeded = records.filter { $0.success && $0.duration > 0 }
        guard !succeeded.isEmpty else { return 0 }
        return succeeded.map { $0.duration }.reduce(0, +) / Double(succeeded.count)
    }

    // MARK: - 引擎控制

    /// 打开工程并启动引擎
    func open(project path: String) {
        // 最近列表里的工程可能已被移动或删除：提示并移出列表，不覆盖当前工程
        guard FileManager.default.fileExists(atPath: path) else {
            appendLog("工程不存在，已从最近打开列表移除：\(path)", level: 3)
            preferences.forgetProject(path)
            return
        }
        preferences.projectPath = path
        preferences.rememberProject(path)
        restartEngine()
    }

    /// 从最近打开列表移除工程（不影响当前工程）
    func forgetProject(_ path: String) {
        preferences.forgetProject(path)
    }

    /// 清空最近打开列表（保留当前工程）
    func clearRecentProjects() {
        preferences.recentProjects = preferences.projectPath.isEmpty ? [] : [preferences.projectPath]
    }

    /// 以当前偏好重启引擎（切换工程、修改 DerivedData / 排除规则后调用）
    func restartEngine() {
        engine?.stop()
        engine = nil
        clients = []
        pendingFiles = []
        // 旧引擎的状态（如红色的出错状态）不能带到新工程上
        state = .idle
        let path = preferences.projectPath
        guard !path.isEmpty else {
            isRunning = false
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            isRunning = false
            appendLog("工程不存在：\(path)。可能已被移动或删除，请重新选择工程", level: 3)
            return
        }
        let derivedData = preferences.customDerivedData.trimmingCharacters(in: .whitespaces)
        let engine = Engine(projectPath: path, customDerivedData: derivedData.isEmpty ? nil : derivedData)
        engine.delegate = self
        notifiedIncompatibleClients.removeAll()
        applyPreferences(to: engine)
        appendLog("打开工程：\(path)", level: 0)
        // 先登记为当前引擎再启动，启动过程中的回调才不会被当成旧引擎的而丢弃
        self.engine = engine
        engine.start()
        isRunning = true
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        clients = []
        isRunning = false
        state = .idle
        appendLog("已停止监听", level: 2)
    }

    /// 断开当前工程：停止监听、断开已连接的 App，并清除"当前工程"（下次启动不再自动打开）。
    /// 工程仍保留在最近打开列表中，可随时重新打开
    func closeProject() {
        guard hasProject else {
            return
        }
        let name = projectName
        engine?.stop()
        engine = nil
        clients = []
        pendingFiles = []
        isRunning = false
        state = .idle
        preferences.projectPath = ""
        appendLog("已断开工程：\(name)", level: 2)
    }

    func injectPendingChanges() {
        engine?.triggerPendingInjection()
    }

    /// 切换当前设备：之后的热重载推给它，并补推它还没有的改动
    func selectDevice(_ client: ClientSummary) {
        guard !client.isActive else {
            return
        }
        // 界面先行切换，引擎随后回报最新状态
        clients = clients.map { item in
            var item = item
            item.isActive = item.id == client.id
            return item
        }
        engine?.selectDevice(client.id)
    }

    /// 手动检查改动（按钮与全局快捷键）：扫描工程目录，把未被监听到的改动交给热重载
    func checkForChanges() {
        guard let engine else {
            appendLog("还没有打开工程，无法检查改动", level: 2, category: .watch)
            return
        }
        engine.checkForChanges()
    }

    func clearLogs() {
        bufferedLogs.removeAll()
        logs.removeAll()
    }

    func clearRecords() {
        records.removeAll()
    }

    func removeRecord(id: UUID) {
        records.removeAll { $0.id == id }
    }

    /// 弹出面板选择工程
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "选择工程"
        panel.message = "选择 .xcodeproj 或 .xcworkspace"
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let ext = url.pathExtension
        guard ext == "xcodeproj" || ext == "xcworkspace" else {
            appendLog("请选择 .xcodeproj 或 .xcworkspace，而不是 \(url.lastPathComponent)", level: 3)
            return
        }
        open(project: url.path)
    }

    /// 清理编译缓存：交给引擎在其工作队列上执行，避免删掉正在编译、尚未推送的 dylib。
    /// 没有运行中的引擎时直接清理。completion 在主线程回调，参数为删除的文件数
    func clearCompileCache(completion: @escaping (Int) -> Void) {
        if let engine {
            engine.clearOutputs { count in
                DispatchQueue.main.async {
                    completion(count)
                }
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let count = Engine.removeOutputs()
            DispatchQueue.main.async {
                completion(count)
            }
        }
    }

    /// 恢复默认设置：DerivedData、排除规则等需要重启引擎才生效的项一并应用
    func resetPreferences() {
        let needsRestart = !preferences.customDerivedData.isEmpty || !preferences.excludedKeywords.isEmpty
        preferences.resetToDefaults()
        if needsRestart, hasProject {
            restartEngine()
        }
    }

    // MARK: - 偏好联动

    private func applyPreferences(to engine: Engine) {
        engine.injectsOnSave = preferences.injectsOnSave
        engine.watchesHeaders = preferences.watchesHeaders
        engine.watchesResources = preferences.watchesResources
        engine.excludedKeywords = preferences.excludedKeywordList
        engine.clientConfig = preferences.clientConfig
    }

    private func observePreferences() {
        // 无需重启即可生效的偏好：变化后直接同步给引擎（App 端配置会实时下发）
        preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange 在赋值前触发，延后一拍读取新值
                DispatchQueue.main.async {
                    guard let self, let engine = self.engine else { return }
                    self.applyPreferences(to: engine)
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - EngineDelegate（均在主线程回调）

    // 每个回调都先确认来自当前引擎：切换工程后旧引擎迟到的回调直接丢弃

    func engine(_ engine: Engine, didChangeState state: EngineState) {
        guard engine === self.engine else { return }
        self.state = state
    }

    func engine(_ engine: Engine, didLog entry: EngineLog) {
        guard engine === self.engine else { return }
        appendLog(entry.message, level: entry.level, category: entry.category, source: entry.source)
    }

    func engine(_ engine: Engine, didUpdateClientCount count: Int) {}

    func engine(_ engine: Engine, didUpdateClients clients: [ClientSummary]) {
        guard engine === self.engine else { return }
        self.clients = clients
        // 客户端与 Mac 端版本不一致：发系统通知提醒重新编译 App（每个连接只提醒一次）
        for client in clients {
            guard let issue = client.compatibilityIssue, notifiedIncompatibleClients.insert(client.id).inserted else {
                continue
            }
            postNotification(title: "\(client.name)：NoCompile 版本不一致",
                             body: "\(issue)。请重新编译并运行 App。", identifier: "incompatible-\(client.id)")
        }
    }

    func engine(_ engine: Engine, didRecord record: InjectionRecord) {
        guard engine === self.engine else { return }
        records.insert(record, at: 0)
        if records.count > 200 {
            records.removeLast(records.count - 200)
        }
        if preferences.playsSounds {
            NSSound(named: record.success ? "Glass" : "Basso")?.play()
        }
        if !record.success && preferences.notifiesOnFailure {
            postFailureNotification(record)
        }
    }

    func engine(_ engine: Engine, didUpdatePendingFiles files: [String]) {
        guard engine === self.engine else { return }
        pendingFiles = files
    }

    // MARK: - 日志

    func appendLog(_ text: String, level: Int, category: LogCategory = .general, source: String? = nil) {
        let date = Date()
        let entry = EngineLog(level: level, category: category, message: text, source: source)
        logWriter.write("[\(timeString(date))] \(entry.plainText)\n")
        let displayed = text.count > maxDisplayedLogLength
            ? String(text.prefix(maxDisplayedLogLength)) + "…（已截断，完整内容见日志文件）"
            : text
        bufferedLogs.append(LogLine(date: date, level: level, category: category, source: source, text: displayed))
        guard !logFlushScheduled else {
            return
        }
        logFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flushLogs()
        }
    }

    /// 把缓冲的日志一次性刷到界面
    private func flushLogs() {
        logFlushScheduled = false
        guard !bufferedLogs.isEmpty else {
            return
        }
        var updated = logs
        updated.append(contentsOf: bufferedLogs)
        bufferedLogs.removeAll()
        let limit = max(200, preferences.maxLogLines)
        if updated.count > limit {
            updated.removeFirst(updated.count - limit)
        }
        logs = updated
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func timeString(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }

    // MARK: - 诊断包

    /// 选择保存位置并导出诊断包（日志、失败现场、卡顿采样、引擎状态、偏好与最近注入记录）
    func exportDiagnostics() {
        guard !isExportingDiagnostics else {
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.message = "诊断包包含日志、编译失败现场与当前配置，可发给开发者排查问题"
        panel.nameFieldStringValue = "NoCompile-Diagnostics-\(formatter.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        isExportingDiagnostics = true
        appendLog("正在导出诊断包…", level: 0)
        flushLogs()
        let appSummary = appDiagnosticsSummary()

        // 引擎可能正忙（例如在编译），最多等 3 秒收集它的状态，超时则不带引擎状态继续导出
        var finished = false
        let proceed: (String) -> Void = { [weak self] engineSummary in
            guard let self, !finished else { return }
            finished = true
            self.writeDiagnostics(to: url, summary: appSummary + "\n\n" + engineSummary)
        }
        if let engine {
            engine.collectDiagnostics(completion: proceed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                proceed("[引擎]\n引擎正忙，3 秒内未能收集状态")
            }
        } else {
            proceed("[引擎]\n未启动")
        }
    }

    private func writeDiagnostics(to url: URL, summary: String) {
        logWriter.flush()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do {
                try Diagnostics.shared.exportBundle(to: url, summary: summary)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExportingDiagnostics = false
                if let failure {
                    self.appendLog("导出诊断包失败：\(failure.localizedDescription)", level: 3)
                } else {
                    self.appendLog("诊断包已导出：\(url.path)", level: 1)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// App 层面的诊断信息：偏好、连接、最近注入记录（含失败原因）
    private func appDiagnosticsSummary() -> String {
        var lines: [String] = ["[偏好]"]
        lines.append("工程：\(preferences.projectPath)")
        lines.append("最近工程：\(preferences.recentProjects.joined(separator: "、"))")
        lines.append("检查改动快捷键：\(preferences.checkChangesHotKey.title)")
        lines.append("自定义 DerivedData：\(preferences.customDerivedData)")
        lines.append("排除关键字：\(preferences.excludedKeywords)")
        lines.append("保存即注入：\(preferences.injectsOnSave)，头文件：\(preferences.watchesHeaders)，资源：\(preferences.watchesResources)")
        lines.append("客户端配置：\(preferences.clientConfig.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        lines.append("引擎运行中：\(isRunning)，状态：\(state)")
        lines.append("")
        lines.append("[已接入设备]")
        if clients.isEmpty {
            lines.append("无")
        }
        for client in clients {
            let flags = (client.isActive ? "［当前］" : "") + (client.isOnline ? "" : "［离线］")
            lines.append("\(flags)\(client.name) @ \(client.deviceName)（\(client.platformTitle) \(client.systemVersion)，\(client.bundleID)，\(client.machine)），"
                + "客户端版本 \(client.clientVersion ?? "未知")，兼容性：\(client.compatibilityIssue ?? "正常")")
        }
        lines.append("")
        lines.append("[最近注入（新→旧，最多 100 条）]")
        for record in records.prefix(100) {
            let status = record.success ? "成功" : "失败"
            var line = "\(Diagnostics.shared.timestamp(record.date))  \(status)  \(record.file) → \(record.clientName) @ \(record.deviceName)（\(record.platformTitle)）\(String(format: "%.2f", record.duration))s"
            if !record.message.isEmpty {
                line += "\n    \(record.message.replacingOccurrences(of: "\n", with: "\n    "))"
            }
            if !record.pending.isEmpty {
                line += "\n    待重进页面：\(record.pending.joined(separator: "、"))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 系统通知

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postFailureNotification(_ record: InjectionRecord) {
        let body = record.message.isEmpty
            ? "\(record.clientName)（\(record.platformTitle)）"
            : String(record.message.prefix(200))
        postNotification(title: "热重载失败：\(record.file)", body: body, identifier: record.id.uuidString)
    }

    private func postNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
