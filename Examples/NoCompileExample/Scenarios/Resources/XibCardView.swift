//
//  XibCardView.swift
//  场景 R12：用 Bundle.loadNibNamed 加载的 xib 视图（File's Owner 是 UIView 子类，常见于自定义卡片 / cell 头）
//

import UIKit

final class XibCardView: UIView {
    @IBOutlet var captionLabel: UILabel?

    static func make() -> XibCardView {
        let owner = XibCardView(frame: .zero)
        Bundle.main.loadNibNamed("XibCardView", owner: owner, options: nil)
        return owner
    }
}
