//
//  A06bProtocolWitness.swift
//  场景 A06b：遵循者自己实现协议要求的方法，经 existential / witness table 调用。
//  witness table 里存的是函数地址，不一定会被符号重绑改到，是 Swift 热重载的经典难点
//

import Foundation

protocol A06bRenderer {
    func render() -> String
}

struct A06bCircle: A06bRenderer {
    func render() -> String {
        return "A06b(@@v1@@)"
    }
}

final class A06bBox: A06bRenderer {
    func render() -> String {
        return "A06b.box(@@v1@@)"
    }
}

enum A06b {
    static func probe() -> String {
        let renderers: [A06bRenderer] = [A06bCircle(), A06bBox()]
        return renderers.map { $0.render() }.joined(separator: "|")
    }
}
