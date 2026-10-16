//
//  AppModel.swift
//  界面状态：持有引擎，汇总状态、连接、注入记录与日志
//

import AppKit
import Combine
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

    let preferences = Preferences.shared
    private var engine: Engine?
    private var cancellables = Set<AnyCancellable>()

    /// 日志文件：~/Library/Logs/NoCompile/NoCompile.log，便于排查与反馈
    let logFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoCompile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("NoCompile.log")
        // 每次启动重新记录
        try? Data().write(to: url)
        return url
    }()

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

    func injectPendingChanges() {
        engine?.triggerPendingInjection()
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearRecords() {
        records.removeAll()
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
        let line = LogLine(date: Date(), level: level, text: text)
        logs.append(line)
        let limit = max(200, preferences.maxLogLines)
        if logs.count > limit {
            logs.removeFirst(logs.count - limit)
        }
        writeToFile(line)
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func timeString(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }

    private func writeToFile(_ line: LogLine) {
        let text = "[\(timeString(line.date))] \(line.text)\n"
        guard let data = text.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    // MARK: - 系统通知

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postFailureNotification(_ record: InjectionRecord) {
        let content = UNMutableNotificationContent()
        content.title = "热重载失败：\(record.file)"
        content.body = record.message.isEmpty
            ? "\(record.clientName)（\(record.platformTitle)）"
            : String(record.message.prefix(200))
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
