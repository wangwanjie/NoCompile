//
//  SwiftGreeter.swift
//  Swift 静态函数热重载验证（静态派发，走函数级重绑）
//

import Foundation

enum SwiftGreeter {
    static func message() -> String {
        // 👉 改这里：修改文案并保存
        return "Swift：第 1 版"
    }
}
