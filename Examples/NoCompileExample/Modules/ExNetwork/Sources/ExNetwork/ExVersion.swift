//
//  ExVersion.swift
//  与 ExKit 里同名的 ExFormatter 区分：两个模块各有一个 moduleName()，符号互不串扰
//

import Foundation

public enum ExFormatter {
    public static func moduleName() -> String {
        return "ExNetwork(@@v1@@)"
    }
}
