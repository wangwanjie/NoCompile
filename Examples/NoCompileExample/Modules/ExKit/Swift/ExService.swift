//
//  ExService.swift
//  场景 M07：跨模块的协议 + 协议扩展默认实现
//

import Foundation

public protocol ExService {
    var name: String { get }
    func run() -> String
}

public extension ExService {
    /// 默认实现：遵循者不实现 run 时使用
    func run() -> String {
        return "ExService.default(@@v1@@):\(name)"
    }

    func describe() -> String {
        return "[\(name)] \(run())"
    }
}
