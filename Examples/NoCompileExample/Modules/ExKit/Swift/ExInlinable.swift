//
//  ExInlinable.swift
//  场景 M11（已知限制）：@inlinable 函数的函数体会被拷贝进调用方，修改后调用方不会拿到新实现，
//  需要重新编译调用方所在的模块
//

import Foundation

public enum ExInlinable {
    @inlinable
    public static func token() -> String {
        return "inlinable(@@v1@@)"
    }

    /// 同一文件里的非 inlinable 函数，用来对照
    public static func plainToken() -> String {
        return "plain(@@v1@@)"
    }
}
