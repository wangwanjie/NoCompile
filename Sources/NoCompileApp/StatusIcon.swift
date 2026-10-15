//
//  StatusIcon.swift
//  状态栏图标：根据引擎状态绘制不同颜色的闪电
//

import AppKit
import NoCompileKit

enum StatusIcon {
    static func image(for state: EngineState) -> NSImage {
        let color: NSColor
        switch state {
        case .idle:
            color = NSColor.systemGreen
        case .working:
            color = NSColor.systemOrange
        case .error:
            color = NSColor.systemRed
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "NoCompile")?
            .withSymbolConfiguration(symbolConfig) {
            color.set()
            let rect = NSRect(x: (size.width - bolt.size.width) / 2,
                              y: (size.height - bolt.size.height) / 2,
                              width: bolt.size.width, height: bolt.size.height)
            bolt.draw(in: rect)
            // 用 sourceAtop 把闪电染色
            color.set()
            rect.fill(using: .sourceAtop)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
