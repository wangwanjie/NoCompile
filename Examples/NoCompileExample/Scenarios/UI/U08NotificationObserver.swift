//
//  U08NotificationObserver.swift
//  场景 U08：Swift 对象在启动时注册 NotificationCenter 观察者（selector + block 两种），
//  热重载后收到通知应执行新实现
//

import Foundation

final class U08Observer: NSObject {
    static let shared = U08Observer()
    private(set) var selectorResult = ""
    private(set) var blockResult = ""
    private var token: NSObjectProtocol?

    static let name = Notification.Name("U08Notification")

    func start() {
        guard token == nil else {
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onNotify(_:)), name: Self.name, object: nil)
        token = NotificationCenter.default.addObserver(forName: Self.name, object: nil, queue: nil) { [unowned self] _ in
            self.blockResult = "block:" + U08Observer.format()
        }
    }

    @objc private func onNotify(_ note: Notification) {
        selectorResult = "selector(@@v1@@)"
    }

    static func format() -> String {
        return "fmt(@@v1@@)"
    }
}

enum U08 {
    static func probe() -> String {
        U08Observer.shared.start()
        NotificationCenter.default.post(name: U08Observer.name, object: nil)
        return "\(U08Observer.shared.selectorResult) \(U08Observer.shared.blockResult)"
    }
}
