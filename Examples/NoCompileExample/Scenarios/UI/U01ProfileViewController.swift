//
//  U01ProfileViewController.swift
//  场景 U01：Swift 页面继承 framework 里的 ObjC 基类 ExBaseViewController（混合继承链），重写它的钩子
//

import UIKit
import ExKit

final class U01ProfileViewController: ExBaseViewController {
    private let nameLabel = UILabel()

    override func exTitle() -> String {
        return "U01(@@v1@@)"
    }

    override func exSetupUI() {
        nameLabel.text = "name:" + makeName()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
    }

    private func makeName() -> String {
        return "profile"
    }
}

enum U01 {
    static func probe() -> String {
        let controller = U01ProfileViewController()
        controller.loadViewIfNeeded()
        return "\(controller.title ?? "-") | \(controller.infoLabel.text ?? "-")"
    }
}
