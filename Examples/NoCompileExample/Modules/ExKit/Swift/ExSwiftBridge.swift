//
//  ExSwiftBridge.swift
//  @objc 暴露给 ObjC 的 Swift 类
//

import Foundation

@objc(ExSwiftBridge)
public final class ExSwiftBridge: NSObject {
    @objc public static func swiftText() -> String {
        return "Swift(@@v1@@)"
    }
}
