//
//  A05UIKitExtension.swift
//  场景 A05c：给 UIKit（ObjC）类型写 Swift 扩展：UIView / UIColor 的方法与 static 属性。
//  符号以 $sSo 开头（ObjC 导入类型），大型工程里这类 UIView+Xxx.swift 非常多
//

import UIKit
import ExKit

extension UIView {
    func a05Tag() -> String {
        return "A05c(@@v1@@)"
    }
}

extension UIColor {
    static var a05Tint: UIColor {
        return UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    }
}
