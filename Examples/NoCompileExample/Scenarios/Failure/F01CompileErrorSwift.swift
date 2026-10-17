//
//  F01CompileErrorSwift.swift
//  场景 F01：Swift 编译错误。App 继续运行旧代码，错误被友好地报出；修复后可恢复
//

import Foundation

enum F01 {
    static func probe() -> String {
        let value: String = "F01(@@v1@@)"
        return value
    }
}
