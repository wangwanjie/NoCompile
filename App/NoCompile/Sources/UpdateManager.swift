//
//  UpdateManager.swift
//  Sparkle 自动更新：检查更新、自动检查 / 自动下载偏好
//
//  更新源（appcast.xml）托管在 GitHub 仓库，安装包托管在 GitHub Releases，
//  地址与 EdDSA 公钥配置在 Info.plist（SUFeedURL / SUPublicEDKey）。
//

import Foundation
import Combine
import Sparkle

final class UpdateManager: NSObject, ObservableObject {

    static let shared = UpdateManager()

    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    /// 当前是否可以发起检查（检查进行中时为 false）
    @Published private(set) var canCheckForUpdates = false

    /// 自动检查更新
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// 自动下载并在退出时安装更新
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    /// 手动检查更新（会弹出 Sparkle 标准界面）
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 上次检查更新的时间
    var lastCheckDate: Date? {
        return controller.updater.lastUpdateCheckDate
    }

    /// 当前版本号，形如 "0.1.0 (1)"
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
