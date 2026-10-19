//
//  ScenarioCatalog.swift
//  场景清单：每个场景对应一个 probe 闭包，返回该场景当前生效的输出。
//
//  端到端脚本（E2E/run_e2e.py）改一个源文件后，读取 ProbeWriter 写出的 JSON，
//  用输出里的 "@@vN@@" 版本令牌判断热重载是否生效。本文件通常不需要修改。
//

import Foundation
import ExKit
import ExCore

struct Scenario {
    let id: String
    let group: String
    let title: String
    /// 主要被修改的文件（相对示例工程目录）
    let file: String
    /// 是否必须在主线程取值（UIKit 对象）
    let onMain: Bool
    let probe: () -> String
}

enum ScenarioCatalog {

    /// 调用 ObjC 类的 +probe（运行时按名字查找，不依赖桥接头）
    private static func objc(_ className: String, selector: String = "probe") -> () -> String {
        return {
            guard let cls = NSClassFromString(className) else {
                return "\(className) missing"
            }
            let result = (cls as AnyObject).perform(NSSelectorFromString(selector))?.takeUnretainedValue()
            return result as? String ?? "\(className).\(selector) returned nil"
        }
    }

    private static func s(_ id: String, _ group: String, _ title: String, _ file: String,
                          main: Bool = false, _ probe: @escaping () -> String) -> Scenario {
        return Scenario(id: id, group: group, title: title, file: file, onMain: main, probe: probe)
    }

    static let all: [Scenario] = [
        // MARK: 原有示例
        s("E01", "Existing", "SwiftGreeter 静态函数", "Shared/SwiftGreeter.swift") { ExampleItems.all()[0].text },
        s("E02", "Existing", "ObjCGreeter 类方法", "Shared/ObjCGreeter.m") { ExampleItems.all()[1].text },
        s("E03", "Existing", "CGreeting C 函数", "Shared/CGreeting.c") { ExampleItems.all()[2].text },
        s("E04", "Existing", "CppCounter C++ 成员函数", "Shared/CppCounter.cpp") { ExampleItems.all()[3].text },
        s("E05", "Existing", "ObjCBadgeView 自定义视图", "iOS/ObjCBadgeView.m", main: true) {
            ResourceProbes.findLabel(in: ObjCBadgeView(frame: .zero))?.text ?? "no-label"
        },
        s("E06", "Existing", "DetailViewController 页面", "iOS/DetailViewController.m", main: true) {
            let controller = DetailViewController()
            controller.loadViewIfNeeded()
            return ResourceProbes.findLabel(in: controller.view)?.text ?? "no-label"
        },

        // MARK: A 系列：Swift
        s("A01", "Swift", "全局函数 / 默认参数 / 可变参数 / throws / private", "Scenarios/Swift/A01SwiftFreeFunctions.swift") { A01.probe() },
        s("A02", "Swift", "struct 静态 / 实例 / mutating", "Scenarios/Swift/A02SwiftStruct.swift") { A02.probe() },
        s("A03", "Swift", "非 final 类 vtable，旧实例走新实现", "Scenarios/Swift/A03SwiftClassVTable.swift") { A03.probe() },
        s("A04", "Swift", "final 单例，状态保留", "Scenarios/Swift/A04SwiftFinalSingleton.swift") { A04.probe() },
        s("A05", "Swift", "自有类的扩展", "Scenarios/Swift/A05ExtensionModel+Extra.swift") { A05.probe() },
        s("A05b", "Swift", "String / Array 扩展", "Scenarios/Swift/A05StringArrayExtension.swift") { A05.probeStringArray() },
        s("A05c", "Swift", "UIView / UIColor 扩展", "Scenarios/Swift/A05UIKitExtension.swift", main: true) { A05.probeUIKit() },
        s("A06", "Swift", "协议扩展默认实现", "Scenarios/Swift/A06ProtocolDefault.swift") { A06.probe() },
        s("A06b", "Swift", "协议 witness（existential 调用）", "Scenarios/Swift/A06bProtocolWitness.swift") { A06b.probe() },
        s("A07", "Swift", "泛型函数 / 泛型结构体", "Scenarios/Swift/A07SwiftGenerics.swift") { A07.probe() },
        s("A08", "Swift", "关联值枚举 / CaseIterable", "Scenarios/Swift/A08SwiftEnum.swift") { A08.probe() },
        s("A09", "Swift", "闭包 / lazy var / 已存闭包", "Scenarios/Swift/A09SwiftClosures.swift") { A09.probe() },
        s("A10", "Swift", "static / 全局变量状态保留", "Scenarios/Swift/A10SwiftStaticState.swift") { A10.probe() },
        s("A11", "Swift", "property wrapper", "Scenarios/Swift/A11SwiftPropertyWrapper.swift") { A11.probe() },
        s("A12", "Swift", "Codable 自定义解码", "Scenarios/Swift/A12SwiftCodable.swift") { A12.probe() },
        s("A13", "Swift", "async / await / actor", "Scenarios/Swift/A13SwiftAsync.swift") { A13.probe() },
        s("A14", "Swift", "@objc dynamic + KVO + selector", "Scenarios/Swift/A14SwiftKVO.swift") { A14.probe() },
        s("A15", "Swift", "Swift 子类继承 ObjC 类", "Scenarios/Swift/A15SwiftOverrideObjC.swift") { A15.probe() },
        s("A16", "Swift", "result builder / 运算符 / 字符串插值", "Scenarios/Swift/A16SwiftSyntaxSugar.swift") { A16.probe() },
        s("A17", "Swift", "Combine 管线", "Scenarios/Swift/A17SwiftCombine.swift") { A17.probe() },
        s("A18", "Swift", "SwiftUI body（静态取值）", "Scenarios/Swift/A18SwiftUIView.swift") { A18.probe() },
        s("A18b", "Swift", "SwiftUI body（运行时渲染）", "Scenarios/Swift/A18bSwiftUIRender.swift", main: true) { A18b.probe() },

        // MARK: B 系列：ObjC
        s("B01", "ObjC", "类方法 / 实例方法 / 私有方法", "Scenarios/ObjC/B01ObjCBasic.m", objc("B01ObjCBasic")),
        s("B02", "ObjC", "自有类的分类（只含分类的 .m）", "Scenarios/ObjC/B02ObjCHost+Extra.m", objc("B02ObjCHost")),
        s("B03", "ObjC", "系统类 NSString 分类", "Scenarios/ObjC/B03NSStringCategory.m", objc("B03Probe")),
        s("B04", "ObjC", "block 属性 / 回调 / GCD", "Scenarios/ObjC/B04ObjCBlocks.m", objc("B04ObjCBlocks")),
        s("B05", "ObjC", "dispatch_once 单例 + static 状态", "Scenarios/ObjC/B05ObjCSingleton.m", objc("B05ObjCSingleton")),
        s("B06", "ObjC", "+load / +initialize / constructor", "Scenarios/ObjC/B06ObjCLoad.m", objc("B06ObjCLoad")),
        s("B07", "ObjC", "+load 里 swizzle", "Scenarios/ObjC/B07SwizzleHost.m", objc("B07SwizzleHost")),
        s("B08", "ObjC", "NS_ENUM / 协议 / 轻量级泛型", "Scenarios/ObjC/B08ObjCTypes.m", objc("B08ObjCTypes")),
        s("B09", "ObjC", "自定义 setter / KVO", "Scenarios/ObjC/B09ObjCProperties.m", objc("B09ObjCProperties")),
        s("B10", "ObjC", "函数指针表 / static C 函数", "Scenarios/ObjC/B10CFunctionTable.m", objc("B10CFunctionTable")),
        s("B11", "ObjC", "extern 常量（数据符号）", "Scenarios/ObjC/B11ObjCConstants.m", objc("B11ObjCConstants")),
        s("B12", "ObjC", "后台高频调用时注入", "Scenarios/ObjC/B12ObjCConcurrency.m", objc("B12ObjCConcurrency")),
        s("B13", "ObjC", "@try/@catch 异常展开", "Scenarios/ObjC/B13ObjCException.m", objc("B13ObjCException")),
        s("B14", "ObjC", "运行时：动态类 / performSelector / 关联对象", "Scenarios/ObjC/B14ObjCRuntime.m", objc("B14ObjCRuntime")),
        s("B15", "ObjC", "宿主类在本文件 new 自己，调用其他文件分类的方法", "Scenarios/ObjC/B15CrossFileCategory.m", objc("B15CrossFileCategory")),

        // MARK: C 系列：C / C++
        s("C01", "C/C++", "C++ 虚函数类层次", "Scenarios/Cpp/C01Shape.cpp", objc("C01CppBridge")),
        s("C02", "C/C++", "头文件 C++ 模板（App）", "Scenarios/Cpp/C02Template.hpp", objc("C02TemplateUser")),
        s("C03", "C/C++", "C++ 异常跨文件抛出 / 捕获", "Scenarios/Cpp/C03Thrower.cpp", objc("C03Catcher")),
        s("C04", "C/C++", "纯 C：结构体 / 可变参数 / 回调", "Scenarios/Cpp/C04CPlain.c", objc("C04CBridge")),
        s("C05", "C/C++", "ObjC++：lambda / std::function", "Scenarios/Cpp/C05ObjCpp.mm", objc("C05ObjCpp")),

        // MARK: H 系列：头文件
        s("H01", "Header", "App 宏头文件（.m/.mm/.c 引用）", "Scenarios/Header/H01Macros.h") {
            let user = objc("H01Users", selector: "appMacroText")()
            let cpp = objc("H01UserCpp")()
            return "\(user) \(cpp) c:\(String(cString: h01_c_text()))"
        },
        s("H01b", "Header", "framework 宏头文件（ExCore/ExMacros.h）", "Modules/ExCore/Public/ExMacros.h") {
            objc("H01Users", selector: "frameworkMacroText")() + " " + ExHeaderUser.macroText()
        },
        s("H02", "Header", "App static inline（ObjC 使用）", "Scenarios/Header/H02Inline.h", objc("H02InlineUser")),
        s("H02b", "Header", "App static inline（Swift 使用）", "Scenarios/Header/H02Inline.h") { H02b.probe() },
        s("H02c", "Header", "framework static inline（ExCore/ExInline.h）", "Modules/ExCore/Public/ExInline.h") {
            objc("H01Users", selector: "frameworkInlineText")() + " " + ExHeaderUser.inlineText()
        },
        s("H03", "Header", "枚举 / 常量宏", "Scenarios/Header/H03Enums.h", objc("H03EnumUser")),
        s("H04", "Header", "PCH 引入的公共头文件", "Scenarios/Header/ExampleCommonPrefix.h", objc("H04PrefixUser")),
        s("H06", "Header", "framework 公开头文件的枚举", "Modules/ExCore/Public/ExConstants.h", objc("H06FrameworkHeaderUser")),
        s("H07", "Header", "静态库头文件 C++ 模板", "Modules/ExPlayer/Sources/ExRingBuffer.hpp") { ModuleProbes.h07() },

        // MARK: M 系列：跨模块
        s("M01", "Module", "ExCore ObjC 单例", "Modules/ExCore/Private/ExLogger.m") { ModuleProbes.m01() },
        s("M02", "Module", "ExCore C 函数", "Modules/ExCore/Private/ExMath.c") { ModuleProbes.m02() },
        s("M03", "Module", "ExKit Swift 公开函数", "Modules/ExKit/Swift/ExFormatter.swift") { ModuleProbes.m03() },
        s("M04", "Module", "App 子类继承 framework 泛型类", "Scenarios/Module/M04ListViewModelSubclass.swift") { M04.probe() },
        s("M04b", "Module", "framework 泛型 open class 本体", "Modules/ExKit/Swift/ExListViewModel.swift") { M04.probe() },
        s("M05", "Module", "framework ObjC 基类（Swift 子类使用）", "Modules/ExKit/Private/ExBaseViewController.m", main: true) { U01.probe() },
        s("M06", "Module", "framework 内 ObjC 调 Swift", "Modules/ExKit/Private/ExObjCUser.m") { ModuleProbes.m06() },
        s("M06b", "Module", "framework 内 @objc Swift 类", "Modules/ExKit/Swift/ExSwiftBridge.swift") { ModuleProbes.m06() },
        s("M07", "Module", "framework 协议默认实现", "Modules/ExKit/Swift/ExService.swift") { M07.probe() },
        s("M07b", "Module", "App 遵循 framework 协议并实现", "Scenarios/Module/M07ServiceConformance.swift") { M07.probe() },
        s("M08", "Module", "静态库 ObjC++（ExPlayerEngine.mm）", "Modules/ExPlayer/Sources/ExPlayerEngine.mm") {
            ModuleProbes.m08() + " " + ModuleProbes.m08b()
        },
        s("M08c", "Module", "静态库 C++（ExPlaylist.cpp）", "Modules/ExPlayer/Sources/ExPlaylist.cpp") { ModuleProbes.m08() },
        s("M08d", "Module", "静态库 C（ExAudioMath.c）", "Modules/ExPlayer/Sources/ExAudioMath.c") { ModuleProbes.m08() },
        s("M09", "Module", "本地 SPM 包：泛型请求", "Modules/ExNetwork/Sources/ExNetwork/ExHTTPClient.swift") { ModuleProbes.m09() },
        s("M09b", "Module", "本地 SPM 包：actor + async", "Modules/ExNetwork/Sources/ExNetwork/ExCache.swift") { ModuleProbes.m09b() },
        s("M10", "Module", "Mediator → ObjC Target", "Scenarios/Module/Target_Player.m") { ModuleProbes.m10() },
        s("M10b", "Module", "Mediator → Swift Target", "Scenarios/Module/M10MediatorTargets.swift") { ModuleProbes.m10() },
        s("M11", "Module", "@inlinable（已知限制）", "Modules/ExKit/Swift/ExInlinable.swift") { ModuleProbes.m11() },
        s("M12", "Module", "framework 关联值枚举", "Modules/ExKit/Swift/ExPlayerState.swift") { ModuleProbes.m12() },
        s("M13", "Module", "同名类型分属两个模块", "Modules/ExNetwork/Sources/ExNetwork/ExVersion.swift") { ModuleProbes.m13() },
        s("M14", "Module", "ExCore 的 NSArray 分类", "Modules/ExCore/Private/NSArray+ExSafe.m") { ModuleProbes.m14() },
        s("M15", "Module", "ExCore 事件总线（通知观察者）", "Modules/ExCore/Private/ExEventBus.m") { ModuleProbes.m15() },
        s("M16", "Module", "ExCore +load swizzle", "Modules/ExCore/Private/ExSwizzleTarget.m") { ModuleProbes.m16() },
        s("M17", "Module", "ExCore 外部常量", "Modules/ExCore/Private/ExConstants.m") { ModuleProbes.m17() },
        s("M18", "Module", "ExCore 的 NSString 分类", "Modules/ExCore/Private/NSString+ExPath.m") { ModuleProbes.m18() },
        s("M19", "Module", "framework 自定义视图（ObjC）", "Modules/ExKit/Private/ExBadgeLabel.m", main: true) {
            let badge = ExBadgeLabel()
            badge.text = "x"
            return badge.renderedText()
        },
        s("M20", "Module", "framework 的 ObjC cell", "Modules/ExKit/Private/ExCardCell.m", main: true) { U03.probe() },
        s("M21", "Module", "framework 里的 UIColor 扩展", "Modules/ExKit/Swift/ExStyle.swift") { "accent=" + UIColor.exAccent.exHex },

        // MARK: U 系列：界面
        s("U01", "UI", "Swift 页面继承 ObjC 基类", "Scenarios/UI/U01ProfileViewController.swift", main: true) { U01.probe() },
        s("U02", "UI", "ObjC 页面", "Scenarios/UI/U02ObjCViewController.m", main: true, objc("U02ObjCViewController")),
        s("U03", "UI", "UITableView + framework cell", "Scenarios/UI/U03TableViewController.swift", main: true) { U03.probe() },
        s("U04", "UI", "UICollectionView + Diffable", "Scenarios/UI/U04CollectionViewController.swift", main: true) { U04.probe() },
        s("U05", "UI", "自定义 UIView 子类", "Scenarios/UI/U05CustomView.swift", main: true) { U05.probe() },
        s("U06", "UI", "父子控制器容器", "Scenarios/UI/U06ContainerViewController.swift", main: true) { U06.probe() },
        s("U08", "UI", "通知观察者（selector + block）", "Scenarios/UI/U08NotificationObserver.swift") { U08.probe() },

        // MARK: R 系列：资源
        s("R01", "Resource", "storyboard 文案", "iOS/Base.lproj/StoryboardDemo.storyboard", main: true) { ResourceProbes.r01Storyboard() },
        s("R02", "Resource", "xib 文案", "iOS/XibDemoViewController.xib", main: true) { ResourceProbes.r02Xib() },
        s("R03", "Resource", "Asset Catalog 图片", "iOS/Assets.xcassets/DemoBadge.imageset/DemoBadge@2x.png", main: true) { ResourceProbes.r03AssetImage() },
        s("R04", "Resource", "散落图片文件", "iOS/Images/loose_icon@2x.png", main: true) { ResourceProbes.r04LooseImage() },
        s("R05", "Resource", "framework 内 xib", "Modules/ExKit/Resources/ExKitBanner.xib", main: true) { ResourceProbes.r05FrameworkXib() },
        s("R06", "Resource", "framework 内 strings", "Modules/ExKit/Resources/ExKit.strings") { ResourceProbes.r06FrameworkStrings() },
        s("R07", "Resource", "framework 内 json", "Modules/ExKit/Resources/kit_config.json") { ResourceProbes.r07FrameworkJSON() },
        s("R08", "Resource", "framework 内 Asset Catalog 图片", "Modules/ExKit/Resources/ExKit.xcassets/KitSquare.imageset/KitSquare@2x.png", main: true) { ResourceProbes.r08FrameworkAsset() },
        s("R09", "Resource", "主 bundle Localizable.strings", "Scenarios/Resources/en.lproj/Localizable.strings") { ResourceProbes.r09MainStrings() },
        s("R10", "Resource", "主 bundle json", "Scenarios/Resources/main_config.json") { ResourceProbes.r10MainJSON() },
        s("R11", "Resource", "颜色集", "iOS/Assets.xcassets/ThemeColor.colorset/Contents.json", main: true) { ResourceProbes.r11ColorSet() },
        s("R12", "Resource", "Bundle.loadNibNamed 加载 view xib", "Scenarios/Resources/XibCardView.xib", main: true) { ResourceProbes.r12ViewXib() },
        s("R13", "Resource", "framework xib 背景色", "Modules/ExKit/Resources/ExKitBanner.xib", main: true) { ResourceProbes.r13FrameworkXibColor() },

        // MARK: S 系列：结构变化
        s("S01", "Structural", "给 NSObject 子类加 @objc 方法", "Scenarios/Structural/S01AddObjCMethod.swift") { S01.probe() },
        s("S02", "Structural", "给 final 类加 Swift 方法", "Scenarios/Structural/S02AddSwiftMethodFinal.swift") { S02.probe() },
        s("S03", "Structural", "给 Swift 类加存储属性", "Scenarios/Structural/S03AddStoredProperty.swift") { S03.probe() },
        s("S04", "Structural", "给 ObjC 类加方法（头文件 + 实现）", "Scenarios/Structural/S04AddObjCMethod.m", objc("S04AddObjCMethod")),
        s("S05", "Structural", "给 ObjC 类加属性", "Scenarios/Structural/S05AddObjCProperty.m", objc("S05AddObjCProperty")),
        s("S06", "Structural", "给 Swift 枚举加 case", "Scenarios/Structural/S06AddEnumCase.swift") { S06.probe() },
        s("S07", "Structural", "改函数签名 + 调用方", "Scenarios/Structural/S07ChangeSignatureCallee.swift") { S07.probe() },
        s("S08", "Structural", "新建 Swift 文件", "Scenarios/Structural/S08NewFileHost.swift") { S08.probe() },
        s("S09", "Structural", "新建 ObjC 类文件", "Scenarios/Structural/S09NewObjCClassHost.m", objc("S09Host")),
        s("S10", "Structural", "删除函数", "Scenarios/Structural/S10RemoveFunction.swift") { S10.probe() },

        // MARK: F 系列：失败路径
        s("F01", "Failure", "Swift 编译错误后恢复", "Scenarios/Failure/F01CompileErrorSwift.swift") { F01.probe() },
        s("F02", "Failure", "ObjC 编译错误后恢复", "Scenarios/Failure/F02CompileErrorObjC.m", objc("F02Host")),
        s("F03", "Failure", "只改注释", "Scenarios/Failure/F03CommentOnly.swift") { F03.probe() },
        s("F04", "Failure", "连续快速保存", "Scenarios/Failure/F04RapidSaves.swift") { F04.probe() },
        s("Z01", "Failure", "先改被调用方、再改调用方", "Scenarios/Failure/Z01CrossFileCaller.swift") { Z01.probe() },
        s("F05", "Failure", "同时保存 Swift / ObjC / C++ 三个文件", "Scenarios/Failure/F05MultiFileA.swift") {
            "\(F05A.text()) \(objc("F05B", selector: "text")()) \(String(cString: f05_c_text()))"
        },
    ]

    static func scenario(id: String) -> Scenario? {
        return all.first { $0.id == id }
    }
}
