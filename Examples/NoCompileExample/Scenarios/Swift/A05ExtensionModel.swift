//
//  A05ExtensionModel.swift
//  场景 A05（基类部分）：类定义在一个文件，扩展在另一个文件
//

import Foundation
import UIKit

final class A05Model {
    let name: String

    init(name: String) {
        self.name = name
    }
}

enum A05 {
    static func probe() -> String {
        return A05Model(name: "m").a05Title()
    }

    static func probeStringArray() -> String {
        return "\("abc".a05Decorated()) \([1, 2, 3].a05Summary())"
    }

    static func probeUIKit() -> String {
        return UIView().a05Tag() + " " + UIColor.a05Tint.exHex
    }
}
