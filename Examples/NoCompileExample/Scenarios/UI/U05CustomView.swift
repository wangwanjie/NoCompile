//
//  U05CustomView.swift
//  场景 U05：自定义 UIView 子类：layoutSubviews / intrinsicContentSize / 子视图 / drawRect 在同一个文件
//

import UIKit

final class U05CustomView: UIView {
    let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "U05(@@v1@@)"
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: 100, height: 40)
    }
}

enum U05 {
    static func probe() -> String {
        let view = U05CustomView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        view.layoutIfNeeded()
        return "\(view.titleLabel.text ?? "-") \(Int(view.intrinsicContentSize.height))"
    }
}
