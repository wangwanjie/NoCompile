//
//  S02AddSwiftMethodFinal.swift
//  场景 S02：给 final 类增加 Swift 方法并调用。final 类静态派发，不涉及 vtable，应立即可用
//

import Foundation

final class S02Model {
    func base() -> String {
        return "S02-base"
    }
    // S02-DECL
}

enum S02 {
    static let longLived = S02Model()

    static func probe() -> String {
        return longLived.base() // S02-CALL
    }
}
