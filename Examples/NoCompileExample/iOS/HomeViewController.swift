//
//  HomeViewController.swift
//  NoCompile iOS 示例首页
//
//  界面全部在 viewDidLoad 中用代码构建。热重载后 NoCompile 会自动重建当前可见页面，
//  因此修改这里的任何布局、文案、颜色，保存后即可看到效果，无需写额外的刷新代码。
//

import UIKit

final class HomeViewController: UIViewController {

    // MARK: - 👉 可修改项：改完保存即可看到效果

    /// 主题色（Swift 实例方法，走 vtable 覆写）
    func themeColor() -> UIColor {
        return .systemIndigo
    }

    /// 顶部标语
    func headline() -> String {
        return "保存即生效，无需重新编译"
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "NoCompile"
        view.backgroundColor = .systemGroupedBackground

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
        ])

        stack.addArrangedSubview(makeHeaderCard())
        for item in ExampleItems.all() {
            stack.addArrangedSubview(makeLanguageCard(item))
        }

        // ObjC 自定义视图：修改 ObjCBadgeView.m 后，所在页面会被自动重建
        let badge = ObjCBadgeView(frame: .zero)
        stack.addArrangedSubview(badge)

        stack.addArrangedSubview(makeDetailButton())
    }

    // MARK: - 组件

    private func makeHeaderCard() -> UIView {
        let card = UIView()
        card.backgroundColor = themeColor()
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous

        let bolt = UILabel()
        bolt.text = "⚡"
        bolt.font = .systemFont(ofSize: 34)

        let title = UILabel()
        title.text = headline()
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .white
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "修改带 👉 标记的代码并保存（⌘S），当前页面会自动刷新"
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.85)
        subtitle.numberOfLines = 0

        let stamp = UILabel()
        stamp.text = ExampleItems.buildStamp()
        stamp.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        stamp.textColor = UIColor.white.withAlphaComponent(0.7)

        let column = UIStackView(arrangedSubviews: [bolt, title, subtitle, stamp])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        return card
    }

    private func makeLanguageCard(_ item: ExampleItem) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous

        let tag = PaddingLabel()
        tag.text = item.language
        tag.font = .systemFont(ofSize: 12, weight: .semibold)
        tag.textColor = themeColor()
        tag.backgroundColor = themeColor().withAlphaComponent(0.12)
        tag.layer.cornerRadius = 6
        tag.layer.masksToBounds = true

        let file = UILabel()
        file.text = item.file
        file.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        file.textColor = .secondaryLabel

        let topRow = UIStackView(arrangedSubviews: [tag, file, UIView()])
        topRow.spacing = 8
        topRow.alignment = .center

        let text = UILabel()
        text.text = item.text
        text.font = .systemFont(ofSize: 17, weight: .medium)
        text.textColor = .label
        text.numberOfLines = 0

        let column = UIStackView(arrangedSubviews: [topRow, text])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func makeDetailButton() -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "打开 Objective-C 页面"
        configuration.baseBackgroundColor = themeColor()
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(openDetail), for: .touchUpInside)
        return button
    }

    @objc private func openDetail() {
        navigationController?.pushViewController(DetailViewController(), animated: true)
    }
}

/// 带内边距的标签，用作语言标签
final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 8, dy: 3))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 16, height: size.height + 6)
    }
}
