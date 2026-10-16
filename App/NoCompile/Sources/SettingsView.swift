//
//  SettingsView.swift
//  偏好设置窗口
//

import SwiftUI
import ServiceManagement
import NoCompileKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettings(model: model, preferences: preferences)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ProjectSettings(model: model, preferences: preferences)
                .tabItem { Label("工程", systemImage: "folder") }
            InjectionSettings(preferences: preferences)
                .tabItem { Label("注入", systemImage: "bolt") }
            AdvancedSettings(model: model, preferences: preferences)
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .frame(width: 560, height: 430)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater = UpdateManager.shared
    @State private var launchAtLogin = false

    var body: some View {
        SettingsPage {
            SettingsSection(title: "更新") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前版本 \(UpdateManager.versionDescription)")
                            .font(.system(size: 13))
                        if let date = updater.lastCheckDate {
                            Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("检查更新…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                SettingToggle(title: "自动检查更新",
                              detail: "通过 GitHub Releases 获取新版本。",
                              isOn: $updater.automaticallyChecksForUpdates)
                SettingToggle(title: "自动下载并安装更新",
                              detail: "后台下载，下次退出时自动安装。",
                              isOn: $updater.automaticallyDownloadsUpdates)
            }
            SettingsSection(title: "热重载") {
                SettingToggle(title: "保存即注入",
                              detail: "保存源文件后自动编译并注入。关闭后改动会累积，在控制台手动注入。",
                              isOn: $preferences.injectsOnSave)
                SettingToggle(title: "监听头文件变更",
                              detail: "修改 .h 时自动重编依赖它的 .m / .mm / .c / .cpp。",
                              isOn: $preferences.watchesHeaders)
                SettingToggle(title: "热重载界面与图片资源",
                              detail: "保存 .storyboard / .xib 后重新编译并刷新对应页面；替换 Asset Catalog 或工程中的图片后，imageNamed: 立即返回新图。",
                              isOn: $preferences.watchesResources)
            }
            SettingsSection(title: "外观与提醒") {
                SettingToggle(title: "在 Dock 中显示图标",
                              detail: "关闭后仅在菜单栏显示 ⚡ 图标。",
                              isOn: $preferences.showsDockIcon)
                SettingToggle(title: "启动时打开控制台",
                              detail: nil,
                              isOn: $preferences.opensConsoleOnLaunch)
                SettingToggle(title: "失败时发送系统通知",
                              detail: "编译或注入失败时弹出通知，便于在 Xcode 中专注编码。",
                              isOn: $preferences.notifiesOnFailure)
                SettingToggle(title: "播放提示音",
                              detail: "注入成功与失败分别播放不同提示音。",
                              isOn: $preferences.playsSounds)
                if #available(macOS 13.0, *) {
                    SettingToggle(title: "登录时自动启动", detail: nil, isOn: $launchAtLogin)
                        .onAppear {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                        .onChange(of: launchAtLogin) { enabled in
                            updateLaunchAtLogin(enabled)
                        }
                }
            }
        }
        .onChange(of: preferences.notifiesOnFailure) { enabled in
            if enabled {
                model.requestNotificationPermission()
            }
        }
    }

    @available(macOS 13.0, *)
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            model.appendLog("设置登录启动失败：\(error.localizedDescription)", level: 3)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - 工程

private struct ProjectSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @State private var derivedDataDraft = ""
    @State private var excludedDraft = ""

    var body: some View {
        SettingsPage {
            SettingsSection(title: "当前工程") {
                HStack(spacing: 8) {
                    Image(systemName: "hammer")
                        .foregroundColor(.secondary)
                    Text(model.hasProject ? preferences.projectPath : "未选择")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("选择…") {
                        model.chooseProject()
                    }
                }
                if preferences.recentProjects.count > 1 {
                    Picker("最近打开", selection: Binding(
                        get: { preferences.projectPath },
                        set: { model.open(project: $0) })) {
                        ForEach(preferences.recentProjects, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                    }
                }
            }
            SettingsSection(title: "构建信息") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DerivedData 路径")
                        .font(.system(size: 12, weight: .medium))
                    HStack {
                        TextField("留空自动检测（含 Xcode 偏好中的自定义位置）", text: $derivedDataDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("浏览…") {
                            browseDerivedData()
                        }
                    }
                    Text("排除路径关键字")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, 6)
                    TextField("例如：Pods/, Tests/（逗号分隔，路径包含任一关键字的文件不触发注入）", text: $excludedDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("应用并重启监听") {
                            preferences.customDerivedData = derivedDataDraft
                            preferences.excludedKeywords = excludedDraft
                            model.restartEngine()
                        }
                        .disabled(!model.hasProject)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onAppear {
            derivedDataDraft = preferences.customDerivedData
            excludedDraft = preferences.excludedKeywords
        }
    }

    private func browseDerivedData() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择工程的 DerivedData 目录，或 DerivedData 根目录"
        if panel.runModal() == .OK, let url = panel.url {
            derivedDataDraft = url.path
        }
    }
}

// MARK: - 注入

private struct InjectionSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        SettingsPage {
            SettingsSection(title: "App 端行为（修改后立即下发到已连接的 App）") {
                SettingToggle(title: "自动刷新受影响的页面",
                              detail: "注入后自动重建当前可见、受改动影响的页面，业务代码无需实现 injected()。",
                              isOn: $preferences.autoReloadViewControllers)
                SettingToggle(title: "保留静态与全局状态",
                              detail: "单例、static 变量沿用注入前的值，不会被重新初始化。",
                              isOn: $preferences.preserveStaticState)
                SettingToggle(title: "显示注入浮层",
                              detail: "在 App 顶部显示「已生效 / 注入失败」提示。",
                              isOn: $preferences.showsHUD)
                SettingToggle(title: "拦截 +load 中的 swizzling",
                              detail: "防止新代码的 +load 重复交换方法导致死循环。",
                              isOn: $preferences.suppressSwizzlingDuringLoad)
            }
        }
    }
}

// MARK: - 高级

private struct AdvancedSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @State private var cacheMessage = ""

    var body: some View {
        SettingsPage {
            SettingsSection(title: "连接") {
                InfoRow(title: "模拟器 / macOS 端口", value: "\(NCProtocol.macPort)")
                InfoRow(title: "真机端口（经 USB）", value: "\(NCProtocol.devicePort)")
            }
            SettingsSection(title: "日志与缓存") {
                Stepper(value: $preferences.maxLogLines, in: 500...20000, step: 500) {
                    Text("控制台保留最近 \(preferences.maxLogLines) 行日志")
                }
                HStack {
                    Button("在访达中显示日志文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.logFileURL])
                    }
                    Button("清理编译缓存") {
                        clearCache()
                    }
                    if !cacheMessage.isEmpty {
                        Text(cacheMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            SettingsSection(title: "重置") {
                Button("恢复默认设置") {
                    preferences.resetToDefaults()
                }
            }
        }
    }

    private func clearCache() {
        let dir = Engine.outputDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
        }
        cacheMessage = "已清理 \(files.count) 个文件"
    }
}

// MARK: - 组件

/// 可滚动的设置页容器
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15)))
        }
        .padding(.bottom, 12)
    }
}

private struct SettingToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}
