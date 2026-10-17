//
//  ResourceProbes.swift
//  资源场景（R 系列）的取值入口：每次都重新加载资源并读出可观察的值，令牌在各资源文件里
//

import UIKit
import ExKit

enum ResourceProbes {
    /// R01：storyboard 里的文案。每次新实例化，等价于"退出页面重进"
    static func r01Storyboard() -> String {
        let storyboard = UIStoryboard(name: "StoryboardDemo", bundle: nil)
        guard let controller = storyboard.instantiateInitialViewController() else {
            return "no-controller"
        }
        controller.loadViewIfNeeded()
        return findLabel(in: controller.view)?.text ?? "no-label"
    }

    /// R02：xib（VC 的 nib）
    static func r02Xib() -> String {
        let controller = XibDemoViewController()
        controller.loadViewIfNeeded()
        return findLabel(in: controller.view)?.text ?? "no-label"
    }

    /// R03：Asset Catalog 图片
    static func r03AssetImage() -> String {
        return UIImage(named: "DemoBadge")?.exPixelSignature ?? "image-missing"
    }

    /// R04：散落的图片文件
    static func r04LooseImage() -> String {
        return UIImage(named: "loose_icon")?.exPixelSignature ?? "image-missing"
    }

    /// R05：framework 里的 xib
    static func r05FrameworkXib() -> String {
        return ExResources.bannerText()
    }

    /// R06：framework 里的 strings
    static func r06FrameworkStrings() -> String {
        return ExResources.localizedTitle()
    }

    /// R07：framework 里的 json
    static func r07FrameworkJSON() -> String {
        return ExResources.jsonValue()
    }

    /// R08：framework 里的 Asset Catalog 图片
    static func r08FrameworkAsset() -> String {
        return ExResources.assetImageSignature()
    }

    /// R09：主 bundle 的 Localizable.strings
    static func r09MainStrings() -> String {
        return NSLocalizedString("r.title", comment: "")
    }

    /// R10：主 bundle 的 json
    static func r10MainJSON() -> String {
        guard let url = Bundle.main.url(forResource: "main_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "json-missing"
        }
        return object["token"] as? String ?? "token-missing"
    }

    /// R11：Asset Catalog 颜色集
    static func r11ColorSet() -> String {
        return UIColor(named: "ThemeColor")?.exHex ?? "color-missing"
    }

    /// R12：Bundle.loadNibNamed 加载的 view xib
    static func r12ViewXib() -> String {
        return XibCardView.make().captionLabel?.text ?? "no-label"
    }

    /// R13：framework 里的 xib 背景色
    static func r13FrameworkXibColor() -> String {
        return ExResources.bannerColorHex()
    }

    static func findLabel(in view: UIView) -> UILabel? {
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
