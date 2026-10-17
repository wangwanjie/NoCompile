//
//  A14SwiftKVO.swift
//  场景 A14：@objc dynamic 属性 + 块式 KVO。dynamic 属性走 ObjC 消息派发
//

import Foundation

final class A14Model: NSObject {
    @objc dynamic var title = "init"

    @objc func reversed() -> String {
        return String(title.reversed()) + "@@v1@@"
    }
}

enum A14 {
    static let model = A14Model()
    static var observed = ""
    static var token: NSKeyValueObservation? = {
        return model.observe(\.title, options: [.new]) { _, change in
            observed = "obs:" + (change.newValue ?? "nil")
        }
    }()

    static func probe() -> String {
        _ = token
        model.title = "abc"
        let viaSelector = model.perform(NSSelectorFromString("reversed"))?.takeUnretainedValue() as? String ?? "nil"
        return "A14 \(observed) \(viaSelector)"
    }
}
