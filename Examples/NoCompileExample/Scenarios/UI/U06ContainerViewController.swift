//
//  U06ContainerViewController.swift
//  场景 U06：父子控制器容器（child VC containment），父子各自的文案在本文件
//

import UIKit

final class U06ChildViewController: UIViewController {
    let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        label.text = "child(@@v1@@)"
        view.addSubview(label)
    }
}

final class U06ContainerViewController: UIViewController {
    let child = U06ChildViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(child)
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
}

enum U06 {
    static func probe() -> String {
        let container = U06ContainerViewController()
        container.loadViewIfNeeded()
        return container.child.label.text ?? "no-text"
    }
}
