//
//  MainViewController.swift
//  NoCompile macOS 示例主界面
//
//  重写了 loadView（自定义根视图）。热重载后 NoCompile 会重新 loadView 并替换窗口内容视图，
//  再走一遍 viewDidLoad，因此修改这里的布局、文案、颜色，保存后即可看到效果。
//

import AppKit

final class MainViewController: NSViewController {

    // MARK: - 👉 可修改项：改完保存即可看到效果

    /// 主题色（Swift 实例方法）
    func themeColor() -> NSColor {
        return .systemIndigo
    }

    /// 顶部标语
    func headline() -> String {
        return "保存即生效，无需重新编译"
    }

    // MARK: - 生命周期

    override func loadView() {
        // 自定义根视图：带背景色的容器
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        let header = makeHeaderCard()
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for item in ExampleItems.all() {
            let card = makeLanguageCard(item)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: - 组件

    private func makeHeaderCard() -> NSView {
        let card = roundedBox(color: themeColor(), radius: 16)

        let title = label("⚡ " + headline(), size: 20, weight: .bold, color: .white)
        let subtitle = label("修改带 👉 标记的代码并保存（⌘S），窗口内容会自动刷新",
                             size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.85))
        let stamp = label(ExampleItems.buildStamp(), size: 11, weight: .medium,
                          color: NSColor.white.withAlphaComponent(0.7))
        stamp.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let column = NSStackView(views: [title, subtitle, stamp])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        pin(column, into: card, inset: 18)
        return card
    }

    private func makeLanguageCard(_ item: ExampleItem) -> NSView {
        let card = roundedBox(color: NSColor.controlBackgroundColor, radius: 12)

        let tag = label(item.language, size: 11, weight: .semibold, color: themeColor())
        let file = label(item.file, size: 11, weight: .regular, color: .secondaryLabelColor)
        file.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let topRow = NSStackView(views: [tag, file])
        topRow.spacing = 8

        let text = label(item.text, size: 16, weight: .medium, color: .labelColor)

        let column = NSStackView(views: [topRow, text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        pin(column, into: card, inset: 14)
        return card
    }

    // MARK: - 小工具

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func roundedBox(color: NSColor, radius: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = color.cgColor
        box.layer?.cornerRadius = radius
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func pin(_ content: NSView, into container: NSView, inset: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }
}
