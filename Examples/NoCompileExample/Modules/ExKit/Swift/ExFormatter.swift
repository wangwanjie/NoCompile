//
//  ExFormatter.swift
//  场景 M03：framework 内的 Swift 公开静态函数，被 App 和 framework 内其他文件调用
//

import Foundation

public enum ExFormatter {
    public static func format(_ value: Int) -> String {
        return "ExFormatter(@@v1@@):\(value)"
    }

    /// 同名枚举在另一个模块（ExNetwork）里也存在：Swift 符号带模块名，不能互相串
    public static func moduleName() -> String {
        return "ExKit"
    }

    /// 带默认参数 / 可变参数 / throws 的公开函数
    public static func join(_ parts: String..., separator: String = "/") throws -> String {
        if parts.isEmpty {
            throw ExFormatError.empty
        }
        return parts.joined(separator: separator)
    }
}

public enum ExFormatError: Error {
    case empty
}
