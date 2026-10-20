//
//  ConsoleView.swift
//  控制台主窗口：状态、已连接 App、注入记录、实时日志
//

import SwiftUI
import NoCompileKit

// MARK: - 主题

enum Theme {
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.95)
    static let success = Color(red: 0.20, green: 0.72, blue: 0.42)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.10)
    static let failure = Color(red: 0.92, green: 0.30, blue: 0.30)

    static func color(for state: EngineState, running: Bool) -> Color {
        guard running else {
            return .secondary
        }
        switch state {
        case .idle: return success
        case .working: return warning
        case .error: return failure
        }
    }

    static func title(for state: EngineState, running: Bool) -> String {
        guard running else {
            return "未启动"
        }
        switch state {
        case .idle: return "就绪"
        case .working: return "编译中"
        case .error: return "出错"
        }
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 1: return success
        case 2: return warning
        case 3: return failure
        default: return .secondary
        }
    }

    /// 日志分类标签的颜色
    static func color(for category: LogCategory) -> NSColor {
        switch category {
        case .general: return .secondaryLabelColor
        case .watch: return .systemTeal
        case .build: return .systemBrown
        case .compile: return .systemOrange
        case .inject: return NSColor(accent)
        case .resource: return .systemPink
        case .connection: return .systemBlue
        case .device: return .systemIndigo
        case .app: return .systemGreen
        }
    }

    static func symbol(forLevel level: Int) -> String {
        switch level {
        case 1: return "checkmark.circle.fill"
        case 2: return "exclamationmark.triangle.fill"
        case 3: return "xmark.octagon.fill"
        default: return "info.circle"
        }
    }
}

// MARK: - 主视图

struct ConsoleView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, preferences: preferences, openSettings: openSettings)
            Divider()
            HStack(spacing: 0) {
                Sidebar(model: model)
                    .frame(width: 320)
                Divider()
                LogConsole(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: - 顶栏

private struct HeaderBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            AppBadge()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.projectName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    StatusPill(state: model.state, running: model.isRunning)
                }
                Text(model.hasProject ? preferences.projectPath : "选择一个 .xcodeproj 或 .xcworkspace 开始热重载")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if !model.pendingFiles.isEmpty {
                Button {
                    model.injectPendingChanges()
                } label: {
                    Label("注入 \(model.pendingFiles.count) 个改动", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .help(model.pendingFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
            }

            if model.isRunning {
                Button {
                    model.checkForChanges()
                } label: {
                    Label("检查改动", systemImage: "arrow.triangle.2.circlepath")
                }
                .help(checkChangesHelp)
            }

            Button {
                model.chooseProject()
            } label: {
                Label(model.hasProject ? "切换工程" : "选择工程", systemImage: "folder")
            }

            // 最近工程列表：当前工程不再重复列出
            let others = preferences.recentProjects.filter { $0 != preferences.projectPath || !model.hasProject }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.self) { path in
                        Button {
                            model.open(project: path)
                        } label: {
                            // 工程名 + 所在目录：同名工程（如多份 kugou.xcworkspace）也能分清
                            Text(Preferences.projectTitle(path))
                        }
                        .help(path)
                    }
                } label: {
                    Label("最近", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("快速切换到最近打开的工程")
            }

            if !model.hasProject, let recent = preferences.recentProjects.first {
                // 断开后可一键重新打开最近的工程
                Button {
                    model.open(project: recent)
                } label: {
                    Label("重新打开 \(Preferences.projectLabel(recent).name)", systemImage: "arrow.clockwise")
                }
                .help(recent)
            }

            if model.hasProject {
                Button {
                    model.closeProject()
                } label: {
                    Label("断开工程", systemImage: "xmark.circle")
                }
                .help("停止监听当前工程并断开已连接的 App；工程保留在最近打开列表中")
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("偏好设置（⌘,）")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(VisualEffect(material: .headerView))
    }

    private var checkChangesHelp: String {
        let shortcut = preferences.checkChangesHotKey == .off ? "" : "（全局快捷键 \(preferences.checkChangesHotKey.title)）"
        return "扫描工程目录，把没有被自动监听到的改动交给热重载\(shortcut)"
    }
}

/// 左上角的应用徽标：直接使用 App 图标
private struct AppBadge: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 46, height: 46)
    }
}

/// 状态胶囊
private struct StatusPill: View {
    let state: EngineState
    let running: Bool

    var body: some View {
        let color = Theme.color(for: state, running: running)
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(Theme.title(for: state, running: running))
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundColor(color)
    }
}

// MARK: - 左栏

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "设备", count: model.clients.count)
                if model.clients.isEmpty {
                    EmptyHint(symbol: "iphone.slash",
                              title: "暂无连接",
                              detail: "在 Xcode 中运行接入了 NoCompile 的 App。\n真机请用数据线连接。")
                } else {
                    if model.clients.count > 1 {
                        Text("热重载只推送到当前设备，点击其他设备即可切换，并自动补推它缺少的改动。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.clients) { client in
                        ClientCard(client: client, selectable: model.clients.count > 1) {
                            model.selectDevice(client)
                        }
                    }
                }

                SectionHeader(title: "最近注入", count: model.records.count, clearHelp: "清除全部注入记录") {
                    model.clearRecords()
                }
                if model.records.isEmpty {
                    EmptyHint(symbol: "bolt.badge.clock",
                              title: "还没有注入记录",
                              detail: "修改源文件并保存（⌘S），这里会显示每次热重载的结果。")
                } else {
                    StatsRow(model: model)
                    RecordList(model: model)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    /// 清除按钮的提示；为 nil 时不显示清除按钮
    var clearHelp: String? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            if count > 0, let onClear {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help(clearHelp ?? "清除")
            }
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.6))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ClientCard: View {
    let client: ClientSummary
    /// 多台设备时可点击切换
    var selectable = false
    var onSelect: () -> Void = {}

    private var symbol: String {
        switch client.platform {
        case "macosx": return "macwindow"
        case "simulator": return client.machine.lowercased().contains("ipad") ? "ipad" : "iphone"
        default: return client.machine.lowercased().hasPrefix("ipad") ? "ipad" : "iphone"
        }
    }

    private var tint: Color {
        switch client.platform {
        case "device": return Theme.accent
        case "simulator": return .blue
        default: return .teal
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(client.platformTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.14)))
                        .foregroundColor(tint)
                }
                Text(deviceLine)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !client.isOnline {
                    Text("App 已退出，重新运行后自动接上并补推改动")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let issue = client.compatibilityIssue {
                    // 版本不一致：完整显示原因并提示重新编译，可换行
                    Label("\(issue)。请重新编译并运行 App", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if client.isActive {
                    Text("当前")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundColor(.white)
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(client.isActive ? Theme.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(client.isActive ? Theme.accent.opacity(0.6) : Color.secondary.opacity(0.12),
                          lineWidth: client.isActive ? 1.5 : 1))
        .opacity(client.isOnline ? 1 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable {
                onSelect()
            }
        }
        .help(selectable && !client.isActive ? "设为当前设备：之后的热重载推送到这台设备" : client.bundleID)
    }

    /// 设备名 · 系统版本 · bundleID
    private var deviceLine: String {
        var parts = [client.deviceName]
        if !client.systemVersion.isEmpty {
            parts.append(client.systemVersion)
        }
        parts.append(client.bundleID)
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if !client.isOnline {
            return .secondary
        }
        return client.compatibilityIssue == nil ? Theme.success : Theme.warning
    }

    private var statusHelp: String {
        if !client.isOnline {
            return "离线"
        }
        return client.compatibilityIssue == nil ? "已连接，客户端 \(client.clientVersion ?? "未知版本")" : "版本不一致，需要重新编译 App"
    }
}

private struct StatsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            StatChip(value: "\(model.successCount)", label: "成功", color: Theme.success)
            StatChip(value: "\(model.failureCount)", label: "失败", color: Theme.failure)
            StatChip(value: String(format: "%.1fs", model.averageDuration), label: "平均耗时", color: Theme.accent)
        }
    }
}

private struct StatChip: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
    }
}

private struct RecordRow: View {
    let record: InjectionRecord
    let time: String
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundColor(record.success ? Theme.success : Theme.failure)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.file)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    // 允许换行完整显示（刷新 / 待重进的页面名可能较长）
                    .fixedSize(horizontal: false, vertical: true)
                if !record.success && !record.message.isEmpty {
                    Text(record.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.failure)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? Theme.accent.opacity(0.18) : (record.success ? Color.clear : Theme.failure.opacity(0.06))))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1))
        .help(String(record.message.prefix(1000)))
    }

    private var subtitle: String {
        var parts = [record.deviceName.isEmpty ? "\(record.clientName) · \(record.platformTitle)" : "\(record.clientName) @ \(record.deviceName)"]
        if record.duration > 0 {
            parts.append(String(format: "%.2fs", record.duration))
        }
        if !record.refreshed.isEmpty {
            parts.append("刷新 \(record.refreshed.joined(separator: "、"))")
        }
        if !record.pending.isEmpty {
            // 已加载的页面未自动重建，提示退出后重新进入
            parts.append("退出重进 \(record.pending.joined(separator: "、")) 即可看到")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 注入记录列表（选中 / 空格预览 / 双击详情）

private extension InjectionRecord {
    /// 记录的完整文本，用于复制与详情展示
    var summaryText: String {
        var lines = ["\(success ? "成功" : "失败")  \(file)",
                     "时间：\(Diagnostics.shared.timestamp(date))",
                     "目标：\(clientName) @ \(deviceName)（\(platformTitle)）"]
        if duration > 0 {
            lines.append(String(format: "耗时：%.2fs", duration))
        }
        if !refreshed.isEmpty {
            lines.append("已刷新：\(refreshed.joined(separator: "、"))")
        }
        if !pending.isEmpty {
            lines.append("待退出重进：\(pending.joined(separator: "、"))")
        }
        if !message.isEmpty {
            lines.append("")
            lines.append(message)
        }
        return lines.joined(separator: "\n")
    }
}

/// 保存键盘事件接收视图的弱引用，便于点击行时把焦点交给它
private final class RecordKeyFocus {
    weak var view: RecordKeyView?

    func claim() {
        guard let view else {
            return
        }
        view.window?.makeFirstResponder(view)
    }
}

/// 接收列表键盘事件的视图：空格预览、方向键切换、回车详情、删除、⌘C 复制
private final class RecordKeyView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onCopy: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }

    /// 编辑菜单的“复制”沿响应链到达这里
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}

private struct RecordKeyCatcher: NSViewRepresentable {
    let focus: RecordKeyFocus
    let onKey: (NSEvent) -> Bool
    let onCopy: () -> Void

    func makeNSView(context: Context) -> RecordKeyView {
        let view = RecordKeyView()
        focus.view = view
        return view
    }

    func updateNSView(_ nsView: RecordKeyView, context: Context) {
        nsView.onKey = onKey
        nsView.onCopy = onCopy
    }
}

private struct RecordList: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: UUID?
    /// 正在空格预览（弹出气泡）的记录
    @State private var previewID: UUID?
    /// 双击打开详情的记录
    @State private var detailRecord: InjectionRecord?
    @State private var focus = RecordKeyFocus()

    private var records: [InjectionRecord] {
        return Array(model.records.prefix(50))
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(records) { record in
                RecordRow(record: record, time: model.timeString(record.date), isSelected: record.id == selectedID)
                    .contentShape(Rectangle())
                    // 双击手势要先于单击声明，否则双击会被单击抢先处理
                    .onTapGesture(count: 2) {
                        select(record)
                        openDetail(record)
                    }
                    .onTapGesture {
                        select(record)
                    }
                    .popover(isPresented: previewBinding(for: record.id), arrowEdge: .trailing) {
                        RecordDetailView(record: record, isPreview: true, onClose: nil)
                    }
                    .contextMenu {
                        Button("预览") {
                            select(record)
                            previewID = record.id
                        }
                        Button("查看详情") {
                            select(record)
                            openDetail(record)
                        }
                        Button("复制") {
                            copy(record)
                        }
                        Divider()
                        Button("删除此记录") {
                            remove(record)
                        }
                    }
            }
        }
        .background(RecordKeyCatcher(focus: focus, onKey: handleKey, onCopy: copySelected))
        .sheet(item: $detailRecord) { record in
            RecordDetailView(record: record, isPreview: false) {
                detailRecord = nil
            }
        }
    }

    private func previewBinding(for id: UUID) -> Binding<Bool> {
        return Binding(get: { previewID == id }, set: { shown in
            if !shown && previewID == id {
                previewID = nil
            }
        })
    }

    private func select(_ record: InjectionRecord) {
        selectedID = record.id
        // 点击后由列表接管键盘，空格 / 方向键才会生效
        focus.claim()
    }

    private func openDetail(_ record: InjectionRecord) {
        previewID = nil
        detailRecord = record
    }

    private func copy(_ record: InjectionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.summaryText, forType: .string)
    }

    private func copySelected() {
        if let record = records.first(where: { $0.id == selectedID }) {
            copy(record)
        }
    }

    private func remove(_ record: InjectionRecord) {
        if previewID == record.id {
            previewID = nil
        }
        if selectedID == record.id {
            selectedID = nil
        }
        model.removeRecord(id: record.id)
    }

    /// 移动选中项；预览中则同步切换预览（类似 Finder 的快速查看）
    private func moveSelection(by offset: Int) {
        guard !records.isEmpty else {
            return
        }
        var index = offset > 0 ? 0 : records.count - 1
        if let current = records.firstIndex(where: { $0.id == selectedID }) {
            index = min(max(current + offset, 0), records.count - 1)
        }
        selectedID = records[index].id
        if previewID != nil {
            previewID = selectedID
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .option, .control]).isEmpty else {
            return false
        }
        let selected = records.first(where: { $0.id == selectedID })
        switch event.keyCode {
        case 49: // 空格：预览 / 关闭预览
            guard let selected else {
                return true
            }
            previewID = previewID == selected.id ? nil : selected.id
            return true
        case 53: // Esc：关闭预览
            guard previewID != nil else {
                return false
            }
            previewID = nil
            return true
        case 36, 76: // 回车：查看详情
            if let selected {
                openDetail(selected)
            }
            return true
        case 125: // 下
            moveSelection(by: 1)
            return true
        case 126: // 上
            moveSelection(by: -1)
            return true
        case 51, 117: // 删除
            if let selected {
                remove(selected)
            }
            return true
        default:
            return false
        }
    }
}

/// 注入记录详情：预览气泡与详情弹窗共用
private struct RecordDetailView: View {
    let record: InjectionRecord
    let isPreview: Bool
    let onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 18))
                    .foregroundColor(record.success ? Theme.success : Theme.failure)
                Text(record.file)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(record.success ? "成功" : "失败")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((record.success ? Theme.success : Theme.failure).opacity(0.14)))
                    .foregroundColor(record.success ? Theme.success : Theme.failure)
            }

            VStack(alignment: .leading, spacing: 4) {
                field("时间", Diagnostics.shared.timestamp(record.date))
                field("目标", "\(record.clientName) @ \(record.deviceName)（\(record.platformTitle)）")
                if record.duration > 0 {
                    field("耗时", String(format: "%.2fs", record.duration))
                }
                if !record.refreshed.isEmpty {
                    field("已刷新", record.refreshed.joined(separator: "、"))
                }
                if !record.pending.isEmpty {
                    field("待重进", record.pending.joined(separator: "、"))
                }
            }

            if !record.message.isEmpty {
                ScrollView {
                    Text(record.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(record.success ? .primary : Theme.failure)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: isPreview ? 160 : .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            } else if !isPreview {
                Spacer(minLength: 0)
            }

            if !isPreview {
                HStack {
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.summaryText, forType: .string)
                    }
                    Spacer()
                    Button("关闭") {
                        onClose?()
                    }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: isPreview ? 360 : 560, height: isPreview ? nil : 420)
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 日志

private enum LogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case important = "警告与错误"
    case errors = "仅错误"
    var id: String { rawValue }

    func accepts(_ level: Int) -> Bool {
        switch self {
        case .all: return true
        case .important: return level >= 2
        case .errors: return level >= 3
        }
    }
}

/// 按来源筛选日志
private enum LogSource: String, CaseIterable, Identifiable {
    case all = "全部来源"
    case engine = "NoCompile"
    case app = "App 日志"
    var id: String { rawValue }

    func accepts(_ category: LogCategory) -> Bool {
        switch self {
        case .all: return true
        case .engine: return category != .app
        case .app: return category == .app
        }
    }
}

private struct LogConsole: View {
    @ObservedObject var model: AppModel
    @State private var filter: LogFilter = .all
    @State private var source: LogSource = .all
    @State private var search = ""
    @State private var followTail = true
    /// 日志字号，⌘+ / ⌘- 缩放并记住
    @AppStorage("logFontSize") private var logFontSize: Double = 12
    @FocusState private var searchFocused: Bool

    private static let minFontSize: Double = 8
    private static let maxFontSize: Double = 32

    private func filteredLogs() -> [LogLine] {
        if filter == .all && source == .all && search.isEmpty {
            return model.logs
        }
        return model.logs.filter { line in
            filter.accepts(line.level) && source.accepts(line.category)
                && (search.isEmpty || line.text.localizedCaseInsensitiveContains(search)
                    || line.category.title.localizedCaseInsensitiveContains(search)
                    || (line.source?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        // 每次刷新只过滤一次（日志多时反复过滤会拖慢主线程）
        let visibleLogs = filteredLogs()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    ForEach(LogFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)

                Picker("", selection: $source) {
                    ForEach(LogSource.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("只看 NoCompile 自身的日志，或只看 App 端转发的日志")

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索日志（⌘F）", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))

                Toggle("跟随最新", isOn: $followTail)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.logFileURL])
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("在访达中显示日志文件")

                Button {
                    model.exportDiagnostics()
                } label: {
                    Image(systemName: "shippingbox")
                }
                .disabled(model.isExportingDiagnostics)
                .help("导出诊断包（日志、编译失败现场、卡顿采样与当前配置），发给开发者排查问题")

                Button {
                    model.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .help("清空日志")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if visibleLogs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(model.logs.isEmpty ? "暂无日志" : "没有匹配的日志")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 用 NSTextView 承载全部日志，支持跨行拖选与复制
                LogTextView(lines: visibleLogs, fontSize: CGFloat(logFontSize), followTail: followTail,
                            timeString: { model.timeString($0) })
            }
        }
        .background(ShortcutMonitor(handler: handleShortcut))
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 日志快捷键：⌘+ / ⌘- 缩放字号，⌘F 聚焦搜索框
extension LogConsole {
    fileprivate func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags.contains(.command), flags.isDisjoint(with: [.option, .control]) else {
            return false
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+":
            zoomLog(by: 1)
            return true
        case "-", "_":
            zoomLog(by: -1)
            return true
        case "f" where !flags.contains(.shift):
            searchFocused = true
            // 已在输入框内时再次 ⌘F，全选便于直接替换关键字
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            return true
        default:
            return false
        }
    }

    fileprivate func zoomLog(by step: Double) {
        logFontSize = min(max(logFontSize + step, Self.minFontSize), Self.maxFontSize)
    }
}

/// 在所属窗口内监听键盘快捷键（独立于焦点所在控件）
private struct ShortcutMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ShortcutMonitorView {
        let view = ShortcutMonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ShortcutMonitorView, context: Context) {
        nsView.handler = handler
    }
}

private final class ShortcutMonitorView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 只处理本视图所在窗口的按键，返回 nil 表示已消费
            guard let self, event.window === self.window, self.handler?(event) == true else {
                return event
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        removeMonitor()
    }
}

/// 日志文本视图：整份日志放进一个 NSTextView，可跨行选择与复制。
/// 日志追加 / 头部裁剪时增量更新文本，避免每次全量重排
private struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    let fontSize: CGFloat
    let followTail: Bool
    let timeString: (Date) -> String

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 10, height: 6)
            textView.isAutomaticLinkDetectionEnabled = false
            context.coordinator.textView = textView
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(lines: lines, fontSize: fontSize, followTail: followTail, timeString: timeString)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        /// 已渲染的日志标识与每行的 UTF-16 长度（含换行），用于增量更新
        private var renderedIDs: [UUID] = []
        private var renderedLengths: [Int] = []
        private var renderedFontSize: CGFloat = 0
        private var wasFollowing = false

        func update(lines: [LogLine], fontSize: CGFloat, followTail: Bool, timeString: @escaping (Date) -> String) {
            guard let textView, let storage = textView.textStorage else {
                return
            }
            let hasSelection = textView.selectedRange().length > 0
            let builder = Builder(fontSize: fontSize, timeString: timeString)

            // 判断能否复用已渲染内容：新列表 = 旧列表去掉头部若干行后再追加若干行
            var dropCount = 0
            var appendFrom = 0
            var reusable = fontSize == renderedFontSize && !renderedIDs.isEmpty && !lines.isEmpty
            if reusable {
                if let start = renderedIDs.firstIndex(of: lines[0].id) {
                    let overlap = renderedIDs.count - start
                    if overlap <= lines.count && lines[overlap - 1].id == renderedIDs.last {
                        dropCount = start
                        appendFrom = overlap
                    } else {
                        reusable = false
                    }
                } else {
                    reusable = false
                }
            }

            var changed = true
            if reusable {
                if dropCount == 0 && appendFrom == lines.count {
                    changed = false
                } else {
                    storage.beginEditing()
                    if dropCount > 0 {
                        let removeLength = renderedLengths.prefix(dropCount).reduce(0, +)
                        storage.deleteCharacters(in: NSRange(location: 0, length: removeLength))
                    }
                    if appendFrom < lines.count {
                        let appended = builder.build(lines[appendFrom...])
                        storage.append(appended.text)
                        renderedLengths.append(contentsOf: appended.lengths)
                    }
                    storage.endEditing()
                    renderedLengths.removeFirst(dropCount)
                }
            } else {
                let built = builder.build(lines[...])
                storage.setAttributedString(built.text)
                renderedLengths = built.lengths
                renderedFontSize = fontSize
            }
            renderedIDs = lines.map { $0.id }

            // 用户正在选择文本时不自动滚动，避免选区被拖走；整体重建或刚打开跟随时仍滚到底部
            let justStartedFollowing = followTail && !wasFollowing
            wasFollowing = followTail
            if followTail && (changed && (!reusable || !hasSelection) || justStartedFollowing) {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    /// 把日志行排成富文本：时间 · 分类 emoji 与彩色标签 · [来源] · 正文（按级别着色）。
    /// 多行正文的续行与正文首行对齐
    private struct Builder {
        let font: NSFont
        let tagFont: NSFont
        let timeString: (Date) -> String

        init(fontSize: CGFloat, timeString: @escaping (Date) -> String) {
            font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            tagFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
            self.timeString = timeString
        }

        func build(_ lines: ArraySlice<LogLine>) -> (text: NSAttributedString, lengths: [Int]) {
            let result = NSMutableAttributedString()
            var lengths: [Int] = []
            for line in lines {
                let piece = render(line)
                lengths.append(piece.length)
                result.append(piece)
            }
            return (result, lengths)
        }

        private func render(_ line: LogLine) -> NSAttributedString {
            let textColor: NSColor
            switch line.level {
            case 3: textColor = NSColor(Theme.failure)
            case 2: textColor = NSColor(Theme.warning)
            case 1: textColor = NSColor(Theme.success)
            default: textColor = line.category == .app ? .secondaryLabelColor : .labelColor
            }
            var background: NSColor?
            if line.level >= 3 {
                background = NSColor(Theme.failure).withAlphaComponent(0.07)
            } else if line.level == 2 {
                background = NSColor(Theme.warning).withAlphaComponent(0.05)
            }

            // 前缀：时间、分类 emoji、分类标签（标签补齐到相同宽度，正文列对齐）
            let prefix = NSMutableAttributedString()
            prefix.append(NSAttributedString(string: timeString(line.date) + " ",
                                             attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            prefix.append(NSAttributedString(string: line.category.emoji + " ", attributes: [.font: font]))
            let tag = line.category.title
            let padding = String(repeating: " ", count: max(0, 4 - Builder.displayWidth(tag)))
            prefix.append(NSAttributedString(string: tag + padding + " ",
                                             attributes: [.font: tagFont, .foregroundColor: Theme.color(for: line.category)]))
            let indent = prefix.size().width

            let first = NSMutableParagraphStyle()
            first.headIndent = indent
            first.lineBreakMode = .byWordWrapping
            // 正文里的换行另起段落，整段缩进到正文列
            let rest = NSMutableParagraphStyle()
            rest.firstLineHeadIndent = indent
            rest.headIndent = indent
            rest.lineBreakMode = .byWordWrapping

            let piece = NSMutableAttributedString(attributedString: prefix)
            if let source = line.source, !source.isEmpty {
                piece.append(NSAttributedString(string: "[\(source)] ",
                                                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let bodyLines = line.text.components(separatedBy: "\n")
            var bodyAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            piece.append(NSAttributedString(string: bodyLines[0], attributes: bodyAttributes))
            piece.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: piece.length))
            bodyAttributes[.paragraphStyle] = rest
            for extra in bodyLines.dropFirst() {
                piece.append(NSAttributedString(string: "\n" + extra, attributes: bodyAttributes))
            }
            piece.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            if let background {
                piece.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: piece.length))
            }
            return piece
        }

        /// 等宽字体下的显示宽度：中文按 2 列计
        private static func displayWidth(_ text: String) -> Int {
            return text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
        }
    }
}

// MARK: - 毛玻璃背景

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
