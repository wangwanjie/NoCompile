//
//  A03SwiftClassVTable.swift
//  场景 A03：非 final 类的 vtable 派发。启动时创建的长寿命实例，热重载后应调用新实现
//

import Foundation

class A03Base {
    func name() -> String {
        return "base"
    }

    func render() -> String {
        return "render:" + name()
    }
}

final class A03Child: A03Base {
    override func name() -> String {
        return "child(@@v1@@)"
    }
}

enum A03 {
    /// 第一次 probe 时（App 启动后、任何注入之前）创建，用来验证"旧实例也走新实现"
    static let longLived: A03Base = A03Child()

    static func probe() -> String {
        return "old[\(longLived.render())] new[\(A03Child().render())]"
    }
}
