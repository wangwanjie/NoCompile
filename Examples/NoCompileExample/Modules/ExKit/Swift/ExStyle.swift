//
//  ExStyle.swift
//  UIKit 扩展 + 全局颜色
//

import UIKit

public extension UIColor {
    /// 框架主题色：场景 UI-color
    static var exAccent: UIColor {
        return UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1)
    }
}

public extension UIView {
    func exRound(_ radius: CGFloat = 12) {
        layer.cornerRadius = radius
        layer.masksToBounds = true
    }
}
