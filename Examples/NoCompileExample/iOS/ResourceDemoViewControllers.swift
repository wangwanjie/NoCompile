//
//  ResourceDemoViewControllers.swift
//  资源热重载示例：界面分别来自 storyboard 与 xib
//
//  修改 Base.lproj/StoryboardDemo.storyboard 或 XibDemoViewController.xib 并保存，
//  停留在对应页面即可看到界面按新的 nib 重建；图片资源改动会同步反映到页面中的图片。
//

import UIKit

/// 界面来自 StoryboardDemo.storyboard
final class StoryboardDemoViewController: UIViewController {
    @IBOutlet var titleLabel: UILabel?
}

/// 界面来自 XibDemoViewController.xib
final class XibDemoViewController: UIViewController {
    @IBOutlet var titleLabel: UILabel?

    init() {
        super.init(nibName: "XibDemoViewController", bundle: nil)
        title = "Xib 页面"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
