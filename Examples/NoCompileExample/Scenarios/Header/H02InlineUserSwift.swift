//
//  H02InlineUserSwift.swift
//  场景 H02b：Swift 经桥接头使用 C 头文件里的 static inline 函数。
//  内联函数的代码由 Swift 编译器（clang importer）生成在 Swift 文件的对象文件里，
//  头文件改动后需要重编这个 Swift 文件
//

import Foundation

enum H02b {
    static func probe() -> String {
        return "swift:" + String(cString: h02_inline_text())
    }
}
