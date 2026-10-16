//
//  StatusIcon.swift
//  菜单栏图标与 App 图标
//

import AppKit
import NoCompileKit

enum StatusIcon {

    /// 菜单栏图标：模板图（自动适配深浅色），由按钮的 contentTintColor 着色
    static func menuBarImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "NoCompile")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// 状态对应的着色：空闲时不着色（跟随菜单栏文字颜色），编译中黄色，出错红色
    static func tint(for state: EngineState, running: Bool) -> NSColor? {
        guard running else {
            return .secondaryLabelColor
        }
        switch state {
        case .idle: return nil
        case .working: return .systemOrange
        case .error: return .systemRed
        }
    }

    /// 运行时绘制的 App 图标：渐变圆角方块 + 白色闪电
    static func appIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40)
        let path = NSBezierPath(roundedRect: rect, xRadius: 96, yRadius: 96)
        let gradient = NSGradient(colors: [
            NSColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1),
            NSColor(red: 0.70, green: 0.35, blue: 0.95, alpha: 1),
        ])
        gradient?.draw(in: path, angle: -60)

        let config = NSImage.SymbolConfiguration(pointSize: 250, weight: .heavy)
        if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tinted = NSImage(size: bolt.size)
            tinted.lockFocus()
            bolt.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            NSRect(origin: .zero, size: bolt.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let boltRect = NSRect(x: (size.width - bolt.size.width) / 2,
                                  y: (size.height - bolt.size.height) / 2,
                                  width: bolt.size.width, height: bolt.size.height)
            tinted.draw(in: boltRect)
        }
        image.unlockFocus()
        return image
    }
}
