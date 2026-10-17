//
//  S01AddObjCMethod.swift
//  场景 S01：给 NSObject 子类增加一个 @objc 方法。ObjC 动态派发：旧实例立即可调用新方法
//

import Foundation

final class S01Model: NSObject {
    @objc func base() -> String {
        return "S01-base"
    }
    // S01-DECL
}

enum S01 {
    static let longLived = S01Model()

    static func probe() -> String {
        // 经 selector 调用：先判断是否响应，方法不存在时返回 none
        let selector = NSSelectorFromString("extra")
        var extra = "none"
        if longLived.responds(to: selector) {
            extra = longLived.perform(selector)?.takeUnretainedValue() as? String ?? "nil"
        }
        return "\(longLived.base()) extra=\(extra)"
    }
}
