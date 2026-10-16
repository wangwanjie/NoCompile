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
}
