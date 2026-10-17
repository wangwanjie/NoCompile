//
//  A09SwiftClosures.swift
//  场景 A09：闭包 / lazy var / 启动时存下的闭包（闭包体本身是旧代码，里面调用的函数应走新实现）
//

import Foundation

func a09Helper() -> String {
    return "A09(@@v1@@)"
}

final class A09Holder {
    /// 启动时就保存的闭包：闭包体是旧代码，但里面调用 a09Helper() 走符号，应拿到新实现
    var stored: () -> String = {
        return "stored:" + a09Helper()
    }

    lazy var lazyValue: String = {
        return "lazy:" + a09Helper()
    }()

    func make() -> () -> String {
        return { [unowned self] in
            return "made:" + a09Helper() + String(self.stored().count)
        }
    }
}

enum A09 {
    static let holder = A09Holder()

    static func probe() -> String {
        let fresh = holder.make()
        return "\(holder.stored()) \(holder.lazyValue) \(fresh())"
    }
}
