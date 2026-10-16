//
//  Preferences.swift
//  偏好设置：持久化到 UserDefaults，变更即时生效
//

import Foundation
import Combine

final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - 通用

    /// 保存即注入；关闭后改动累积为"待注入"，需手动触发
    @Published var injectsOnSave: Bool { didSet { save(injectsOnSave, "injectsOnSave") } }
    /// 监听头文件变更，自动重编依赖它的实现文件
    @Published var watchesHeaders: Bool { didSet { save(watchesHeaders, "watchesHeaders") } }
    /// 热重载资源文件：storyboard、xib 与图片
    @Published var watchesResources: Bool { didSet { save(watchesResources, "watchesResources") } }
    /// 在 Dock 中显示图标（关闭后仅在菜单栏显示）
    @Published var showsDockIcon: Bool { didSet { save(showsDockIcon, "showsDockIcon") } }
    /// 启动时打开控制台窗口
    @Published var opensConsoleOnLaunch: Bool { didSet { save(opensConsoleOnLaunch, "opensConsoleOnLaunch") } }
    /// 编译 / 注入失败时发送系统通知
    @Published var notifiesOnFailure: Bool { didSet { save(notifiesOnFailure, "notifiesOnFailure") } }
    /// 注入成功 / 失败时播放提示音
    @Published var playsSounds: Bool { didSet { save(playsSounds, "playsSounds") } }

    // MARK: - 工程

    /// 当前工程（.xcodeproj / .xcworkspace）
    @Published var projectPath: String { didSet { save(projectPath, "projectPath") } }
    /// 最近打开的工程
    @Published var recentProjects: [String] { didSet { save(recentProjects, "recentProjects") } }
    /// 自定义 DerivedData 路径，留空自动检测
    @Published var customDerivedData: String { didSet { save(customDerivedData, "customDerivedData") } }
    /// 不触发注入的路径关键字，逗号或换行分隔
    @Published var excludedKeywords: String { didSet { save(excludedKeywords, "excludedKeywords") } }

    // MARK: - 注入（下发到 App 端）

    /// 注入后自动重建受影响的可见页面
    @Published var autoReloadViewControllers: Bool { didSet { save(autoReloadViewControllers, "autoReloadViewControllers") } }
    /// 保留静态 / 全局变量的状态，避免单例被重建
    @Published var preserveStaticState: Bool { didSet { save(preserveStaticState, "preserveStaticState") } }
    /// 在 App 内显示注入状态浮层
    @Published var showsHUD: Bool { didSet { save(showsHUD, "showsHUD") } }
    /// 加载新代码时拦截 +load 中的 method swizzling
    @Published var suppressSwizzlingDuringLoad: Bool { didSet { save(suppressSwizzlingDuringLoad, "suppressSwizzlingDuringLoad") } }

    // MARK: - 高级

    /// 日志窗口保留的最大行数
    @Published var maxLogLines: Int { didSet { save(maxLogLines, "maxLogLines") } }

    private init() {
        // 初始化阶段不能访问 self，使用局部引用读取
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            return defaults.object(forKey: key) as? Bool ?? fallback
        }
        injectsOnSave = bool("injectsOnSave", true)
        watchesHeaders = bool("watchesHeaders", true)
        watchesResources = bool("watchesResources", true)
        showsDockIcon = bool("showsDockIcon", true)
        opensConsoleOnLaunch = bool("opensConsoleOnLaunch", true)
        notifiesOnFailure = bool("notifiesOnFailure", true)
        playsSounds = bool("playsSounds", false)
        projectPath = defaults.string(forKey: "projectPath") ?? ""
        recentProjects = defaults.stringArray(forKey: "recentProjects") ?? []
        customDerivedData = defaults.string(forKey: "customDerivedData") ?? ""
        excludedKeywords = defaults.string(forKey: "excludedKeywords") ?? ""
        autoReloadViewControllers = bool("autoReloadViewControllers", true)
        preserveStaticState = bool("preserveStaticState", true)
        showsHUD = bool("showsHUD", true)
        suppressSwizzlingDuringLoad = bool("suppressSwizzlingDuringLoad", true)
        maxLogLines = defaults.object(forKey: "maxLogLines") as? Int ?? 2000
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// 下发给 App 端的配置
    var clientConfig: [String: Any] {
        return [
            "autoReloadViewControllers": autoReloadViewControllers,
            "preserveStaticState": preserveStaticState,
            "showsHUD": showsHUD,
            "suppressSwizzlingDuringLoad": suppressSwizzlingDuringLoad,
        ]
    }

    /// 解析后的排除关键字
    var excludedKeywordList: [String] {
        return excludedKeywords
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 记录最近打开的工程（最多 8 个）
    func rememberProject(_ path: String) {
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        recentProjects = Array(list.prefix(8))
    }

    /// 恢复默认设置（保留当前工程与最近工程）
    func resetToDefaults() {
        injectsOnSave = true
        watchesHeaders = true
        watchesResources = true
        showsDockIcon = true
        opensConsoleOnLaunch = true
        notifiesOnFailure = true
        playsSounds = false
        customDerivedData = ""
        excludedKeywords = ""
        autoReloadViewControllers = true
        preserveStaticState = true
        showsHUD = true
        suppressSwizzlingDuringLoad = true
        maxLogLines = 2000
    }
}
