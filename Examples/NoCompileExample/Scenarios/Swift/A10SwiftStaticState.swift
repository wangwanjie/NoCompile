//
//  A10SwiftStaticState.swift
//  场景 A10：static / 全局变量的状态在重新注入后必须保留（计数不能被重置）
//

import Foundation

var a10Global = 0

enum A10 {
    static var counter = 0
    static let registry = NSMutableArray()

    static func tick() -> String {
        counter += 1
        a10Global += 10
        registry.add(counter)
        return "A10(@@v1@@) n=\(counter) g=\(a10Global) r=\(registry.count)"
    }

    static func probe() -> String {
        return tick()
    }
}
