#!/usr/bin/env swift
//
// generate_icons.swift
// 生成 NoCompile 的 App 图标（程序化矢量绘制，无外部素材）。
//
// 用法（在仓库根目录）：swift Scripts/generate_icons.swift
// 输出：
//   App/NoCompile/Assets.xcassets/AppIcon.appiconset/（全部尺寸 + Contents.json）
//   Docs/images/AppIcon.png（README 展示用，512px）
//
// 设计：macOS 图标网格内的圆角方块；靛蓝 → 紫色渐变底，右下角粉色暖光；
// 背景一对淡色代码括号 { } 点出"代码"；中央一道白→暖黄渐变的闪电表示"即时生效"。
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSetDir = root.appendingPathComponent("App/NoCompile/Assets.xcassets/AppIcon.appiconset")
let docsImageDir = root.appendingPathComponent("Docs/images")

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    return CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

/// 四角星光
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let inner = radius * 0.22
    path.move(to: CGPoint(x: center.x, y: center.y + radius))
    path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + inner, y: center.y + inner))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x + inner, y: center.y - inner))
    path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - inner, y: center.y - inner))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x - inner, y: center.y + inner))
    path.closeSubpath()
    return path
}

/// 在 1024×1024 画布上绘制图标
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS 图标网格：内容区 824×824，居中，圆角约 185
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 1. 底部投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: srgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(srgb(0x4F46E5))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 主体渐变：左上靛蓝 → 右下紫
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([srgb(0x4338CA), srgb(0x6D28D9), srgb(0x9333EA)], [0, 0.55, 1]),
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY),
                           options: [])
    // 右下角粉色暖光
    ctx.drawRadialGradient(gradient([srgb(0xF472B6, 0.55), srgb(0xF472B6, 0)], [0, 1]),
                           startCenter: CGPoint(x: 860, y: 180), startRadius: 0,
                           endCenter: CGPoint(x: 860, y: 180), endRadius: 520,
                           options: [])
    // 左上角高光
    ctx.drawRadialGradient(gradient([srgb(0xFFFFFF, 0.28), srgb(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 280, y: 830), startRadius: 0,
                           endCenter: CGPoint(x: 280, y: 830), endRadius: 560,
                           options: [])

    // 3. 背景代码括号 { }
    let braceFont = NSFont.monospacedSystemFont(ofSize: 330, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: braceFont,
        .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12),
    ]
    let braces = NSAttributedString(string: "{ }", attributes: attributes)
    let line = CTLineCreateWithAttributedString(braces)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: 512 - bounds.midX, y: 512 - bounds.midY)
    CTLineDraw(line, ctx)

    // 内描边：让边缘更有玻璃质感
    ctx.addPath(tilePath)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. 闪电
    let bolt = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: 0.625, y: 0.900),
        CGPoint(x: 0.235, y: 0.445),
        CGPoint(x: 0.475, y: 0.445),
        CGPoint(x: 0.375, y: 0.100),
        CGPoint(x: 0.765, y: 0.565),
        CGPoint(x: 0.525, y: 0.565),
    ]
    // 映射到内容区中央 640×640
    let boltRect = CGRect(x: 192, y: 192, width: 640, height: 640)
    func map(_ p: CGPoint) -> CGPoint {
        return CGPoint(x: boltRect.minX + p.x * boltRect.width, y: boltRect.minY + p.y * boltRect.height)
    }
    bolt.move(to: map(points[0]))
    for p in points.dropFirst() {
        bolt.addLine(to: map(p))
    }
    bolt.closeSubpath()

    // 闪电投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: srgb(0x1E1B4B, 0.6))
    ctx.addPath(bolt)
    ctx.setFillColor(srgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // 闪电渐变填充：白 → 暖黄
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    ctx.drawLinearGradient(gradient([srgb(0xFFFFFF), srgb(0xFEF3C7), srgb(0xFCD34D)], [0, 0.5, 1]),
                           start: CGPoint(x: 512, y: boltRect.maxY),
                           end: CGPoint(x: 512, y: boltRect.minY),
                           options: [])
    ctx.restoreGState()

    // 闪电高光描边
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.55))
    ctx.setLineWidth(5)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // 5. 星光点缀
    let sparkles: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: 770, y: 775), 44, 0.95),
        (CGPoint(x: 838, y: 680), 20, 0.75),
        (CGPoint(x: 250, y: 290), 28, 0.80),
    ]
    for (center, radius, alpha) in sparkles {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: srgb(0xFFFFFF, 0.8))
        ctx.addPath(sparklePath(center: center, radius: radius))
        ctx.setFillColor(srgb(0xFFFFFF, alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// 渲染指定像素尺寸的 PNG
func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS AppIcon 所需尺寸
let specs: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: iconSetDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: docsImageDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for spec in specs {
    let pixels = spec.points * spec.scale
    let name = "icon_\(spec.points)x\(spec.points)\(spec.scale == 2 ? "@2x" : "").png"
    try renderPNG(pixels: pixels).write(to: iconSetDir.appendingPathComponent(name))
    images.append([
        "idiom": "mac",
        "size": "\(spec.points)x\(spec.points)",
        "scale": "\(spec.scale)x",
        "filename": name,
    ])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSetDir.appendingPathComponent("Contents.json"))

// Assets.xcassets 根目录的 Contents.json
let catalogContents = try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]],
                                                 options: [.prettyPrinted, .sortedKeys])
try catalogContents.write(to: iconSetDir.deletingLastPathComponent().appendingPathComponent("Contents.json"))

try renderPNG(pixels: 512).write(to: docsImageDir.appendingPathComponent("AppIcon.png"))
print("✅ 图标已生成：\(iconSetDir.path)")
