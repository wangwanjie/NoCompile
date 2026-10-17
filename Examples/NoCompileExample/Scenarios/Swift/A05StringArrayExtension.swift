//
//  A05StringArrayExtension.swift
//  场景 A05b：给 Swift 标准库类型（String、Array）写扩展。符号以 $sSS / $sSa 开头，容易被误判成标准库符号
//

import Foundation

extension String {
    func a05Decorated() -> String {
        return "<@@v1@@" + self + ">"
    }
}

extension Array where Element == Int {
    func a05Summary() -> String {
        return "n=\(count)"
    }
}
