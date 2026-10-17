//
//  M10MediatorTargets.swift
//  场景 M10：组件化 Target_xxx 类，经 NSClassFromString + objc_msgSend 动态调用（大型工程里的常见做法）。
//  Swift 的 Target 用 @objc(Target_Settings) 指定 ObjC 名
//

import Foundation

@objc(Target_Settings)
final class M10SettingsTarget: NSObject {
    @objc func Action_info(_ params: NSDictionary?) -> NSString {
        return "Settings(@@v1@@)"
    }
}
