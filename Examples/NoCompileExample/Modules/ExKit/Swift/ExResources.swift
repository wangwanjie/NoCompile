//
//  ExResources.swift
//  framework 自带资源（xib / asset catalog / strings / json）的访问入口
//

import UIKit

public enum ExResources {
    /// framework 自己的 bundle（不是 Bundle.main）
    public static var bundle: Bundle {
        let base = Bundle(for: ExBundleToken.self)
        // CocoaPods 把资源放进 framework 内的 ExKit.bundle；工程直接集成时资源就在 framework 里
        if let url = base.url(forResource: "ExKit", withExtension: "bundle"), let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return base
    }

    /// framework 内 xib 的文案
    public static func bannerText() -> String {
        let nib = UINib(nibName: "ExKitBanner", bundle: bundle)
        let objects = nib.instantiate(withOwner: nil, options: nil)
        guard let view = objects.first as? UIView else {
            return "nib-missing"
        }
        return findLabel(in: view)?.text ?? "label-missing"
    }

    public static func bannerColorHex() -> String {
        let nib = UINib(nibName: "ExKitBanner", bundle: bundle)
        guard let view = nib.instantiate(withOwner: nil, options: nil).first as? UIView else {
            return "nib-missing"
        }
        return view.backgroundColor?.exHex ?? "no-color"
    }

    public static func localizedTitle() -> String {
        return NSLocalizedString("kit.title", tableName: "ExKit", bundle: bundle, comment: "")
    }

    public static func jsonValue() -> String {
        guard let url = bundle.url(forResource: "kit_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "json-missing"
        }
        return object["token"] as? String ?? "token-missing"
    }

    public static func assetImageSignature() -> String {
        guard let image = UIImage(named: "KitSquare", in: bundle, compatibleWith: nil) else {
            return "image-missing"
        }
        return image.exPixelSignature
    }

    private static func findLabel(in view: UIView) -> UILabel? {
        if let label = view as? UILabel {
            return label
        }
        for sub in view.subviews {
            if let found = findLabel(in: sub) {
                return found
            }
        }
        return nil
    }
}

final class ExBundleToken {}

public extension UIColor {
    /// 取 RGB 十六进制
    var exHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

public extension UIImage {
    /// 取图片中心像素的颜色作为签名，用来判断图片是否被替换
    var exPixelSignature: String {
        guard let cgImage = cgImage else {
            return "no-cgimage"
        }
        let width = cgImage.width, height = cgImage.height
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "no-context"
        }
        context.draw(cgImage, in: CGRect(x: -(width / 2), y: -(height / 2), width: width, height: height))
        return String(format: "%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}
