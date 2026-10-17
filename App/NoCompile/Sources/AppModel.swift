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
    let text: String
}

final class AppModel: ObservableObject, EngineDelegate {

    static let shared = AppModel()

    @Published private(set) var state: EngineState = .idle
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
        return LogFileWriter(url: logFileURL, truncate: true)
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
        preferences.projectPath = path
        preferences.rememberProject(path)
        restartEngine()
    }

    /// 以当前偏好重启引擎（切换工程、修改 DerivedData / 排除规则后调用）
    func restartEngine() {
        engine?.stop()
        engine = nil
        clients = []
        pendingFiles = []
        let path = preferences.projectPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            isRunning = false
            return
        }
        let derivedData = preferences.customDerivedData.trimmingCharacters(in: .whitespaces)
        let engine = Engine(projectPath: path, customDerivedData: derivedData.isEmpty ? nil : derivedData)
        engine.delegate = self
        notifiedIncompatibleClients.removeAll()
        applyPreferences(to: engine)
        appendLog("打开工程：\(path)", level: 0)
        engine.start()
        self.engine = engine
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

    func engine(_ engine: Engine, didChangeState state: EngineState) {
        self.state = state
    }

    func engine(_ engine: Engine, didLog message: String, level: Int) {
        appendLog(message, level: level)
    }

    func engine(_ engine: Engine, didUpdateClientCount count: Int) {}

    func engine(_ engine: Engine, didUpdateClients clients: [ClientSummary]) {
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
        pendingFiles = files
    }

    // MARK: - 日志

    func appendLog(_ text: String, level: Int) {
        let date = Date()
        logWriter.write("[\(timeString(date))] \(text)\n")
        let displayed = text.count > maxDisplayedLogLength
            ? String(text.prefix(maxDisplayedLogLength)) + "…（已截断，完整内容见日志文件）"
            : text
        bufferedLogs.append(LogLine(date: date, level: level, text: displayed))
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
        lines.append("自定义 DerivedData：\(preferences.customDerivedData)")
        lines.append("排除关键字：\(preferences.excludedKeywords)")
        lines.append("保存即注入：\(preferences.injectsOnSave)，头文件：\(preferences.watchesHeaders)，资源：\(preferences.watchesResources)")
        lines.append("客户端配置：\(preferences.clientConfig.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        lines.append("引擎运行中：\(isRunning)，状态：\(state)")
        lines.append("")
        lines.append("[已连接 App]")
        if clients.isEmpty {
            lines.append("无")
        }
        for client in clients {
            lines.append("\(client.name)（\(client.platformTitle)，\(client.bundleID)，\(client.machine)），客户端版本 \(client.clientVersion ?? "未知")，"
                + "兼容性：\(client.compatibilityIssue ?? "正常")")
        }
        lines.append("")
        lines.append("[最近注入（新→旧，最多 100 条）]")
        for record in records.prefix(100) {
            let status = record.success ? "成功" : "失败"
            var line = "\(Diagnostics.shared.timestamp(record.date))  \(status)  \(record.file) → \(record.clientName)（\(record.platformTitle)）\(String(format: "%.2f", record.duration))s"
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
