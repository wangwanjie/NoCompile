//
//  A01SwiftFreeFunctions.swift
//  场景 A01：Swift 全局函数 / 默认参数 / 可变参数 / throws / private 与 fileprivate 函数
//

import Foundation

enum A01 {
    static func probe() -> String {
        let joined = (try? a01Join("x", "y")) ?? "err"
        return "\(a01Plain()) \(a01WithDefault()) sum=\(a01Variadic(1, 2, 3)) \(joined) \(a01Hidden())"
    }
}

func a01Plain() -> String {
    return "A01(@@v1@@)"
}

func a01WithDefault(prefix: String = "d") -> String {
    return prefix + a01Private()
}

private func a01Private() -> String {
    return "p"
}

fileprivate func a01Hidden() -> String {
    return "h"
}

func a01Variadic(_ numbers: Int...) -> Int {
    return numbers.reduce(0, +)
}

func a01Join(_ a: String, _ b: String) throws -> String {
    if a.isEmpty {
        throw NSError(domain: "A01", code: 1)
    }
    return a + b
}
