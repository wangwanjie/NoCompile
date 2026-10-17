//
//  A06ProtocolDefault.swift
//  场景 A06：协议扩展里的默认实现（静态派发 / 通过 witness 调用），遵循者没有自己的实现
//

import Foundation

protocol A06Shape {
    var name: String { get }
    func area() -> Int
}

extension A06Shape {
    /// 协议扩展里的默认实现
    func label() -> String {
        return "A06(@@v1@@):\(name)=\(area())"
    }
}

struct A06Square: A06Shape {
    let name = "square"
    func area() -> Int {
        return 4
    }
}

enum A06 {
    static func probe() -> String {
        let shapes: [A06Shape] = [A06Square()]
        return shapes.map { $0.label() }.joined(separator: ",")
    }
}
