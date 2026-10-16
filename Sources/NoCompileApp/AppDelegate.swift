//
//  AppDelegate.swift
//  App 外壳：控制台窗口、偏好设置窗口、Dock 与菜单栏图标、主菜单
//

import AppKit
import SwiftUI
import Combine
import NoCompileKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let model = AppModel.shared
    private let preferences = Preferences.shared
    private var statusItem: NSStatusItem?
    private var consoleWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = StatusIcon.appIcon()
        applyDockPolicy()
        buildMainMenu()
        setupStatusItem()
        observeModel()

        if preferences.notifiesOnFailure {
            model.requestNotificationPermission()
        }

        // 优先使用启动参数 --project，其次恢复上次的工程
        if let path = launchArgumentProject(), FileManager.default.fileExists(atPath: path) {
            model.open(project: path)
        } else if model.hasProject, FileManager.default.fileExists(atPath: preferences.projectPath) {
            model.restartEngine()
        } else {
            model.appendLog("欢迎使用 NoCompile。点击右上角「选择工程」打开 .xcodeproj 或 .xcworkspace。", level: 0)
        }

        if preferences.opensConsoleOnLaunch || !model.hasProject {
            showConsole()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标时重新打开控制台
        if !flag {
            showConsole()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭窗口后继续在后台监听
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopEngine()
    }

    /// 解析启动参数：--project <路径>
    private func launchArgumentProject() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--project"), index + 1 < args.count else {
            return nil
        }
        let path = args[index + 1]
        if (path as NSString).isAbsolutePath {
            return (path as NSString).standardizingPath
        }
        return (FileManager.default.currentDirectoryPath + "/" + path as NSString).standardizingPath
    }

    // MARK: - 窗口

    @objc func showConsole() {
        if consoleWindow == nil {
            let root = ConsoleView(model: model, preferences: preferences, openSettings: { [weak self] in
                self?.showSettings()
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "NoCompile"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentViewController = NSHostingController(rootView: root)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("NoCompileConsole")
            if !window.setFrameUsingName("NoCompileConsole") {
                window.setContentSize(NSSize(width: 1080, height: 680))
                window.center()
            }
            consoleWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        consoleWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "NoCompile 偏好设置"
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, preferences: preferences))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dock 与菜单栏

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(preferences.showsDockIcon ? .regular : .accessory)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NoCompileStatusItem"
        item.isVisible = true
        item.button?.image = StatusIcon.menuBarImage()
        item.button?.toolTip = "NoCompile"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        statusItem?.button?.contentTintColor = StatusIcon.tint(for: model.state, running: model.isRunning)
    }

    private func observeModel() {
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusIcon()
                }
            }
            .store(in: &cancellables)
        preferences.$showsDockIcon
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyDockPolicy()
                    // 切换为仅菜单栏后保持窗口在前台
                    self?.consoleWindow?.makeKeyAndOrderFront(nil)
                }
            }
            .store(in: &cancellables)
    }

    /// 菜单打开前按当前状态重建，保证内容最新
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let stateTitle: String
        switch model.state {
        case .idle: stateTitle = model.isRunning ? "● 就绪" : "○ 未启动"
        case .working: stateTitle = "● 编译中…"
        case .error: stateTitle = "● 出错，详见控制台"
        }
        menu.addItem(disabledItem(stateTitle))
        menu.addItem(disabledItem("工程：\(model.projectName)"))
        menu.addItem(disabledItem("已连接：\(model.clients.isEmpty ? "无" : model.clients.map { "\($0.name)（\($0.platformTitle)）" }.joined(separator: "、"))"))
        if let last = model.records.first {
            menu.addItem(disabledItem("最近：\(last.success ? "✓" : "✗") \(last.file)"))
        }

        menu.addItem(.separator())
        if !model.pendingFiles.isEmpty {
            menu.addItem(actionItem("注入 \(model.pendingFiles.count) 个待处理改动", #selector(injectPending), "i"))
        }
        menu.addItem(actionItem("打开控制台", #selector(showConsole), "0"))
        menu.addItem(actionItem(model.hasProject ? "切换工程…" : "选择工程…", #selector(chooseProject), "o"))

        if preferences.recentProjects.count > 1 {
            let recent = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for path in preferences.recentProjects {
                let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
                item.state = path == preferences.projectPath ? .on : .off
                submenu.addItem(item)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }

        menu.addItem(.separator())
        let saveItem = actionItem("保存即注入", #selector(toggleInjectOnSave), "")
        saveItem.state = preferences.injectsOnSave ? .on : .off
        menu.addItem(saveItem)
        menu.addItem(actionItem("偏好设置…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 NoCompile", #selector(quit), "q"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func injectPending() {
        model.injectPendingChanges()
    }

    @objc private func chooseProject() {
        model.chooseProject()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            model.open(project: path)
        }
    }

    @objc private func toggleInjectOnSave() {
        preferences.injectsOnSave.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 主菜单（Dock 模式下显示在屏幕顶部）

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 NoCompile", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(actionItem("偏好设置…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 NoCompile", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(actionItem("退出 NoCompile", #selector(quit), "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(actionItem("选择工程…", #selector(chooseProject), "o"))
        fileMenu.addItem(actionItem("注入待处理改动", #selector(injectPending), "i"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // 编辑菜单：让日志、输入框支持复制粘贴
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(actionItem("控制台", #selector(showConsole), "0"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
