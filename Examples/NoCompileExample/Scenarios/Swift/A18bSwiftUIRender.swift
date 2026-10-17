//
//  A18bSwiftUIRender.swift
//  场景 A18b：用 ImageRenderer 经 SwiftUI 运行时真正求值 body（走 witness table），读取渲染出的像素色
//

import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct A18bView: View {
    var body: some View {
        // 👉 红色分量：0.2 → 51(0x33)，改成 0.8 → 204(0xCC)
        Color(red: 0.2, green: 0.0, blue: 0.0)
            .frame(width: 20, height: 20)
    }
}

enum A18b {
    /// 必须在主线程调用（ImageRenderer 要求主线程）
    static func probe() -> String {
        guard #available(iOS 16.0, *) else {
            return "A18b unavailable"
        }
        return MainActor.assumeIsolated {
            render()
        }
    }

    @available(iOS 16.0, *)
    @MainActor
    private static func render() -> String {
        let renderer = ImageRenderer(content: A18bView())
        renderer.scale = 1
        guard let image = renderer.uiImage else {
            return "A18b no-image"
        }
        return "A18b red=\(image.a18bCenterRed())"
    }
}

private extension UIImage {
    func a18bCenterRed() -> String {
        guard let cgImage = cgImage else {
            return "no-cg"
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "no-ctx"
        }
        context.draw(cgImage, in: CGRect(x: -(cgImage.width / 2), y: -(cgImage.height / 2),
                                         width: cgImage.width, height: cgImage.height))
        return String(format: "%02X", pixel[0])
    }
}
