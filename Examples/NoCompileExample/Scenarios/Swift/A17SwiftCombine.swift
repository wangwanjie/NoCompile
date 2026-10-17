//
//  A17SwiftCombine.swift
//  场景 A17：Combine 管线，map 闭包在本文件
//

import Combine
import Foundation

enum A17 {
    static let subject = PassthroughSubject<Int, Never>()
    static var received: [String] = []
    static var cancellable: AnyCancellable?

    static func probe() -> String {
        if cancellable == nil {
            // 管线在第一次 probe 时建立（热重载前）；其中 map 闭包是旧代码，闭包调用的 a17Format 走新实现
            cancellable = subject.map { a17Format($0) }.sink { received.append($0) }
        }
        subject.send(received.count)
        return "A17 last=\(received.last ?? "-") n=\(received.count)"
    }
}

func a17Format(_ value: Int) -> String {
    return "A17(@@v1@@):\(value)"
}
