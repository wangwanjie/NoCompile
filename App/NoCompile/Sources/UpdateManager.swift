//
//  UpdateManager.swift
//  Sparkle 自动更新：检查更新、自动检查 / 自动下载偏好
//
//  更新源托管在 GitHub 仓库，安装包托管在 GitHub Releases，
//  地址与 EdDSA 公钥配置在 Info.plist（SUFeedURL / SUPublicEDKey）。
//  arm64 与 x86_64 分别发布：各架构的 App 读取 appcast-<arch>.xml，只收到同架构的更新。
//  Apple 芯片的 Mac 上误装了 Intel 版（在 Rosetta 下运行）时，改读 arm64 的 feed，下次更新即换成原生版本。
//

import Foundation
import Combine
import Sparkle

final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {

    static let shared = UpdateManager()

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    /// 当前是否可以发起检查（检查进行中时为 false）
    @Published private(set) var canCheckForUpdates = false

    /// 上次检查更新的时间（随 Sparkle 的记录实时更新）
    @Published private(set) var lastCheckDate: Date?

    /// 自动检查更新
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    /// 自动下载并在退出时安装更新
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            if controller.updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
                controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
        }
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        // 与 Sparkle 双向同步：Sparkle 首次启动询问用户、或在其他地方修改设置后，界面跟着更新
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.lastCheckDate = value
            }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                if self?.automaticallyChecksForUpdates != value {
                    self?.automaticallyChecksForUpdates = value
                }
            }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                if self?.automaticallyDownloadsUpdates != value {
                    self?.automaticallyDownloadsUpdates = value
                }
            }
            .store(in: &cancellables)
    }

    /// 手动检查更新（会弹出 Sparkle 标准界面）
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Rosetta 下运行的 Intel 版改读 arm64 的 feed；其余情况返回 nil，沿用 Info.plist 的 SUFeedURL
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard Self.isRunningUnderRosetta,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feed.hasSuffix("/appcast-x86_64.xml") else {
            return nil
        }
        return String(feed.dropLast("appcast-x86_64.xml".count)) + "appcast-arm64.xml"
    }

    // MARK: - 架构信息

    /// 本进程是否经 Rosetta 转译运行（Apple 芯片上运行 Intel 版）
    static let isRunningUnderRosetta: Bool = {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 else {
            return false
        }
        return translated == 1
    }()

    /// 当前安装包的架构
    static var appArchitecture: String {
        #if arch(arm64)
        return "Apple 芯片（arm64）"
        #else
        return isRunningUnderRosetta ? "Intel（x86_64，经 Rosetta 转译运行）" : "Intel（x86_64）"
        #endif
    }

    /// 当前版本号，形如 "0.1.0 (1)"
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
