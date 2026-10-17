//
//  A07SwiftGenerics.swift
//  场景 A07：泛型函数 / 泛型结构体 / 带约束的泛型方法
//

import Foundation

func a07Describe<T: CustomStringConvertible>(_ value: T) -> String {
    return "A07(@@v1@@):\(value)"
}

struct A07Stack<Element> {
    private var items: [Element] = []

    mutating func push(_ item: Element) {
        items.append(item)
    }

    func summary() -> String {
        return "stack(\(items.count))"
    }
}

enum A07 {
    static func probe() -> String {
        var stack = A07Stack<String>()
        stack.push("a")
        stack.push("b")
        return "\(a07Describe(42)) \(a07Describe("s")) \(stack.summary())"
    }
}
