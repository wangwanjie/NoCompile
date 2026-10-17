//
//  AppDelegate.swift
//  NoCompile iOS 示例
//
//  注意：业务代码中没有任何 NoCompile 相关的调用或 import。
//  客户端随 Debug 构建链入后会自动启动，保存源文件即可在运行中的 App 看到改动。
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 端到端脚本启动时设置 EXAMPLE_PROBE_FILE，周期性导出全部场景的当前输出
        ProbeWriter.startIfRequested()
        EarlyStarters.start()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// 启动时就要开始的后台活动（B12 高频调用、U08 观察者等）
enum EarlyStarters {
    static func start() {
        NSClassFromString("B12ObjCConcurrency").flatMap { cls in
            _ = (cls as AnyObject).perform(NSSelectorFromString("startTicking"))
        }
        U08Observer.shared.start()
    }
}
