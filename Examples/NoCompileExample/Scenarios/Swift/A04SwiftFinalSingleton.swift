//
//  A04SwiftFinalSingleton.swift
//  场景 A04：final 类 + static let 单例 + 实例状态。热重载后单例与状态保留，方法体更新
//

import Foundation

final class A04Service {
    static let shared = A04Service()

    private(set) var calls = 0

    func ping() -> String {
        calls += 1
        return "A04(@@v1@@) calls=\(calls)"
    }
}

enum A04 {
    static func probe() -> String {
        return A04Service.shared.ping()
    }
}
