//
//  S10RemoveFunction.swift
//  场景 S10：删除一个函数。其他文件不再引用它，注入后不应崩溃
//

import Foundation

func s10Kept() -> String {
    return "S10(@@v1@@)"
}

// S10-REMOVABLE
func s10Removable() -> String {
    return "removable"
}

enum S10 {
    static func probe() -> String {
        return s10Kept()
    }
}
