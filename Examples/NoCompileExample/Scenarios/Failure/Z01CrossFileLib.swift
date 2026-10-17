//
//  Z01CrossFileLib.swift
//  场景 Z01：先改被调用方，再改调用方。后注入的调用方 dylib 必须绑定到被调用方的最新实现
//

import Foundation

func z01Lib() -> String {
    return "lib(@@v1@@)"
}
