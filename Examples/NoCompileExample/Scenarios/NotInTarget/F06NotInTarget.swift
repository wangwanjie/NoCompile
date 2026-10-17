//
//  F06NotInTarget.swift
//  场景 F06：位于工程目录下、但不属于任何 target 的源文件（project.yml 里 excludes 了本目录）。
//  保存后 NoCompile 应给出"找不到编译命令"的提示，不能崩溃，也不影响 App
//

import Foundation

enum F06 {
    static func text() -> String {
        return "F06(@@v1@@)"
    }
}
