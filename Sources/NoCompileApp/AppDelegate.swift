//
//  AppDelegate.swift
//  菜单栏 App：承载引擎、状态图标、菜单与偏好。
//

import AppKit
import NoCompileKit

final class AppDelegate: NSObject, NSApplicationDelegate, EngineDelegate {

    private var statusItem: NSStatusItem!
    private let logWindow = LogWindowController()
    private var engine: Engine?
    private var state: EngineState = .idle
    private var clientCount = 0

    private let defaults = UserDefaults.standard
    private var projectPath: String? {
        get { defaults.string(forKey: "projectPath") }
        set { defaults.set(newValue, forKey: "projectPath") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()

        // 自动恢复上次工程
        if let path = projectPath, FileManager.default.fileExists(atPath: path) {
            startEngine(projectPath: path)
        }
    }

    // MARK: - 引擎

    private func startEngine(projectPath: String) {
        engine?.stop()
        let engine = Engine(projectPath: projectPath)
        engine.delegate = self
        engine.injectsOnSave = defaults.object(forKey: "injectsOnSave") as? Bool ?? true
        engine.watchesHeaders = defaults.object(forKey: "watchesHeaders") as? Bool ?? true
        engine.start()
        self.engine = engine
        self.projectPath = projectPath
        logWindow.showWindow(nil)
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        let menu = NSMenu()

        let projectTitle = projectPath.map { "工程：\(($0 as NSString).lastPathComponent)" } ?? "未选择工程"
        let projectItem = NSMenuItem(title: projectTitle, action: nil, keyEquivalent: "")
        projectItem.isEnabled = false
        menu.addItem(projectItem)

        let clientItem = NSMenuItem(title: "已连接 App：\(clientCount)", action: nil, keyEquivalent: "")
        clientItem.isEnabled = false
        menu.addItem(clientItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "选择工程…", action: #selector(selectProject), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "显示日志", action: #selector(showLog), keyEquivalent: "l"))

        menu.addItem(.separator())
        let injectItem = NSMenuItem(title: "保存即注入", action: #selector(toggleInjectOnSave), keyEquivalent: "")
        injectItem.state = (defaults.object(forKey: "injectsOnSave") as? Bool ?? true) ? .on : .off
        menu.addItem(injectItem)

        let headerItem = NSMenuItem(title: "监听头文件变更", action: #selector(toggleWatchHeaders), keyEquivalent: "")
        headerItem.state = (defaults.object(forKey: "watchesHeaders") as? Bool ?? true) ? .on : .off
        menu.addItem(headerItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 NoCompile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(for: state)
    }

    @objc private func selectProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "选择 .xcodeproj 或 .xcworkspace"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            startEngine(projectPath: url.path)
            rebuildMenu()
        }
    }

    @objc private func showLog() {
        NSApp.activate(ignoringOtherApps: true)
        logWindow.showWindow(nil)
    }

    @objc private func toggleInjectOnSave() {
        let value = !(defaults.object(forKey: "injectsOnSave") as? Bool ?? true)
        defaults.set(value, forKey: "injectsOnSave")
        engine?.injectsOnSave = value
        rebuildMenu()
    }

    @objc private func toggleWatchHeaders() {
        let value = !(defaults.object(forKey: "watchesHeaders") as? Bool ?? true)
        defaults.set(value, forKey: "watchesHeaders")
        engine?.watchesHeaders = value
        rebuildMenu()
    }

    // MARK: - EngineDelegate

    func engine(_ engine: Engine, didChangeState state: EngineState) {
        self.state = state
        updateIcon()
    }

    func engine(_ engine: Engine, didLog message: String, level: Int) {
        logWindow.append(message, level: level)
    }

    func engine(_ engine: Engine, didUpdateClientCount count: Int) {
        clientCount = count
        rebuildMenu()
    }
}
