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

            Toggle(isOn: $preferences.injectsOnSave) {
                Text("保存即注入")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("关闭后，改动会累积为待注入，点击按钮手动注入")

            Button {
                model.chooseProject()
            } label: {
                Label(model.hasProject ? "切换工程" : "选择工程", systemImage: "folder")
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
                SectionHeader(title: "已连接 App", count: model.clients.count)
                if model.clients.isEmpty {
                    EmptyHint(symbol: "iphone.slash",
                              title: "暂无连接",
                              detail: "在 Xcode 中运行接入了 NoCompile 的 App。\n真机请用数据线连接。")
                } else {
                    ForEach(model.clients) { client in
                        ClientCard(client: client)
                    }
                }

                SectionHeader(title: "最近注入", count: model.records.count)
                if model.records.isEmpty {
                    EmptyHint(symbol: "bolt.badge.clock",
                              title: "还没有注入记录",
                              detail: "修改源文件并保存（⌘S），这里会显示每次热重载的结果。")
                } else {
                    StatsRow(model: model)
                    ForEach(model.records.prefix(50)) { record in
                        RecordRow(record: record, time: model.timeString(record.date))
                    }
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

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
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
                Text(client.bundleID)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(Theme.success)
                .frame(width: 7, height: 7)
                .help("已连接")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.12)))
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
                    .lineLimit(2)
                if !record.success && !record.message.isEmpty {
                    Text(record.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.failure)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(record.success ? Color.clear : Theme.failure.opacity(0.06)))
        .help(record.message)
    }

    private var subtitle: String {
        var parts = ["\(record.clientName) · \(record.platformTitle)"]
        if record.duration > 0 {
            parts.append(String(format: "%.2fs", record.duration))
        }
        if !record.refreshed.isEmpty {
            parts.append("刷新 \(record.refreshed.joined(separator: "、"))")
        }
        return parts.joined(separator: " · ")
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

private struct LogConsole: View {
    @ObservedObject var model: AppModel
    @State private var filter: LogFilter = .all
    @State private var search = ""
    @State private var followTail = true

    private var visibleLogs: [LogLine] {
        model.logs.filter { line in
            filter.accepts(line.level) && (search.isEmpty || line.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
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

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索日志", text: $search)
                        .textFieldStyle(.plain)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleLogs) { line in
                                LogRow(line: line, time: model.timeString(line.date))
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.logs.count) { _ in
                        if followTail, let last = visibleLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = visibleLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LogRow: View {
    let line: LogLine
    let time: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
            Image(systemName: Theme.symbol(forLevel: line.level))
                .font(.system(size: 10))
                .foregroundColor(Theme.color(forLevel: line.level))
                .frame(width: 12)
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(line.level >= 3 ? Theme.failure : (line.level == 2 ? Theme.warning : .primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(line.level >= 3 ? Theme.failure.opacity(0.06) : Color.clear)
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
