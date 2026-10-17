//
//  ResourceCompiler.swift
//  资源热重载的 Mac 端准备工作：把改动的界面文件 / 图片整理成可下发给 App 的资源包。
//
//  - storyboard / xib：用 ibtool 编译成 .storyboardc / .nib（优先沿用构建日志里的 ibtool 参数）
//  - 散落的图片文件：连同同名的其他倍率一起下发
//  - Asset Catalog 图片集（.imageset）：读取 Contents.json，按倍率 / 设备类型下发其中的位图
//
//  资源包内的相对路径与 App 资源目录（Bundle.main.resourcePath）一致，
//  客户端据此在镜像 bundle 中覆盖对应条目，并按名字替换 imageNamed: 的结果。
//

import Foundation

public enum ResourceKind: String {
    case storyboard
    case nib
    case image
    /// 其他原样拷贝进 bundle 的资源：json、plist、strings、音频、字体等
    case file
    /// Asset Catalog 里的颜色集
    case colorset
}

/// 一个准备好下发的资源包
public struct ResourcePackage {
    public let kind: ResourceKind
    public let source: String
    /// storyboard 名 / nib 名 / 图片名（与代码里 storyboardWithName:、nibWithNibName:、imageNamed: 的参数一致）
    public let name: String
    /// 本地暂存根目录，其下的目录结构与 App 资源目录一致
    public let rootDirectory: String
    /// 需要覆盖进 App bundle 的条目（相对资源目录），如 "Base.lproj/Main.storyboardc"
    public let items: [String]
    /// rootDirectory 下的全部文件（相对路径），真机按此顺序拼接传输
    public let files: [String]
    /// 图片变体：path（相对 rootDirectory）、scale、idiom
    public let images: [[String: Any]]
    /// 图片集是否声明为模板渲染
    public let isTemplate: Bool
    /// 资源所属 bundle 在构建产物里的目录名，如 "ExKit.framework"、"ExampleiOS.app"、"Foo.bundle"；
    /// 未能确定时形如 "module:Xxx"（按模块名找 bundle），nil 表示主 bundle
    public var bundle: String? = nil
    /// 颜色集的颜色（kind 为 colorset 时）：red / green / blue / alpha（0~1）
    public var color: [String: Double]? = nil

    /// 下发给客户端的描述（不含文件内容）
    public var json: [String: Any] {
        var result: [String: Any] = [
            "kind": kind.rawValue,
            "source": source,
            "name": name,
            "items": items,
            "images": images,
            "template": isTemplate,
        ]
        if let bundle {
            result["bundle"] = bundle
        }
        if let color {
            result["color"] = color
        }
        return result
    }
}

/// 资源整理结果
public enum ResourcePreparation {
    case ready(ResourcePackage)
    /// 无需处理或该平台用不到（如 App 图标、另一平台的界面文件），附带原因
    case skipped(String)
    case failed(String)
}

public final class ResourceCompiler {

    private let outputDirectory: String
    private var counter = 0

    public init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }

    /// 是否为资源文件（其余交给 Recompiler 当源码处理）
    public static func isResource(_ path: String) -> Bool {
        return FileWatcher.resourceExtensions.contains((path as NSString).pathExtension.lowercased())
            || path.hasSuffix("/Contents.json")
    }

    /// 同一批改动中可合并处理的资源标识：同一图片集、同目录下同名不同倍率的图片只需下发一次
    public static func batchKey(for file: String) -> String {
        if let imageset = enclosingDirectory(of: file, withExtension: "imageset") {
            return imageset
        }
        if let colorset = enclosingDirectory(of: file, withExtension: "colorset") {
            return colorset
        }
        let ext = (file as NSString).pathExtension.lowercased()
        if ext == "storyboard" || ext == "xib" {
            return file
        }
        let parsed = parseImageFileName((file as NSString).lastPathComponent)
        return "\((file as NSString).deletingLastPathComponent)/\(parsed.name).\(parsed.ext)"
    }

    /// 整理一个资源文件
    public func prepare(file: String,
                        commands: ParsedCommands,
                        platform: Platform) -> ResourcePreparation {
        let result = prepareCore(file: file, commands: commands, platform: platform)
        guard case .ready(var package) = result else {
            // 没有产出资源包：清掉暂存目录
            try? FileManager.default.removeItem(atPath: "\(outputDirectory)/res_\(counter)")
            return result
        }
        package.bundle = Self.bundleHint(for: file, kind: package.kind, commands: commands)
        return .ready(package)
    }

    private func prepareCore(file: String,
                             commands: ParsedCommands,
                             platform: Platform) -> ResourcePreparation {
        counter += 1
        let root = "\(outputDirectory)/res_\(counter)"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let ext = (file as NSString).pathExtension.lowercased()
        switch ext {
        case "storyboard", "xib":
            return compileInterface(file: file, root: root, commands: commands, platform: platform)
        default:
            if Self.enclosingDirectory(of: file, withExtension: "colorset") != nil {
                return prepareColorSet(file, root: root)
            }
            if let imageset = Self.enclosingDirectory(of: file, withExtension: "imageset") {
                return prepareImageSet(imageset, source: file, root: root, platform: platform)
            }
            if file.contains(".xcassets/") {
                // App 图标等其他 Asset Catalog 条目：运行时无法替换
                return .skipped("App 图标等 Asset Catalog 条目运行时无法替换，需重新运行 App")
            }
            if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp"].contains(ext) {
                // 构建日志里没有这张图片的拷贝记录，说明它不是 App 的资源（文档配图等）。
                // 旧缓存里没有任何拷贝记录时（还没解析过新日志）不做这个判断
                if commands.resourceDestinations.isEmpty || Self.hasBuildRecord(for: file, commands: commands) {
                    return prepareLooseImage(file, root: root)
                }
                return .skipped("")
            }
            return prepareDataFile(file, root: root, commands: commands)
        }
    }

    /// 构建日志里是否有这个文件的拷贝记录（没有记录说明它不是 App 的资源）
    private static func hasBuildRecord(for file: String, commands: ParsedCommands) -> Bool {
        return commands.resourceDestinations[ParsedCommands.canonicalPath(file)] != nil
    }

    // MARK: - 所属 bundle

    private static let bundleExtensions: Set<String> = ["app", "framework", "bundle", "appex", "xctest"]

    /// 路径（含自身）最内层的 bundle 目录名，如 ".../ExKit.framework/Headers/a.h" → "ExKit.framework"
    static func productBundleName(containing path: String) -> String? {
        var current = path
        while current.count > 1 {
            if bundleExtensions.contains((current as NSString).pathExtension) {
                return (current as NSString).lastPathComponent
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 资源所属 bundle：优先用构建日志里的拷贝 / 编译目标，storyboard 退而求其次用 ibtool 的 --module
    static func bundleHint(for file: String, kind: ResourceKind, commands: ParsedCommands) -> String? {
        let canonical = ParsedCommands.canonicalPath(file)
        if let destination = commands.resourceDestinations[canonical], let bundle = productBundleName(containing: destination) {
            return bundle
        }
        // 图片集 / 颜色集：看所在 .xcassets 的编译输出目录
        var directory = (canonical as NSString).deletingLastPathComponent
        while directory.count > 1 {
            if directory.hasSuffix(".xcassets") {
                if let destination = commands.resourceDestinations[directory], let bundle = productBundleName(containing: destination) {
                    return bundle
                }
                break
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        // 散落图片的其他倍率文件：同目录下兄弟文件的目标所在 bundle
        if kind == .image {
            let folder = (canonical as NSString).deletingLastPathComponent
            let parsed = parseImageFileName((canonical as NSString).lastPathComponent)
            for (source, destination) in commands.resourceDestinations
            where (source as NSString).deletingLastPathComponent == folder
                && parseImageFileName((source as NSString).lastPathComponent).name == parsed.name {
                if let bundle = productBundleName(containing: destination) {
                    return bundle
                }
            }
        }
        if let module = commands.ibtoolCommand(for: file)?.moduleName {
            return "module:\(module)"
        }
        return nil
    }

    // MARK: - 原样拷贝的资源 / 颜色集

    /// json、plist、strings、音频、字体等：必须是构建日志里记录过的资源拷贝，才按它在 bundle 里的相对路径下发
    private func prepareDataFile(_ file: String, root: String, commands: ParsedCommands) -> ResourcePreparation {
        guard let destination = commands.resourceDestinations[ParsedCommands.canonicalPath(file)],
              let bundle = Self.productBundleName(containing: destination) else {
            // 不是 App 的资源（构建配置、脚本数据等）：静默忽略
            return .skipped("")
        }
        guard let relative = Self.pathInsideBundle(destination) else {
            return .skipped("")
        }
        let target = "\(root)/\(relative)"
        try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard Self.copyBytes(from: file, to: target) else {
            return .failed("无法读取资源文件：\(file)")
        }
        _ = bundle
        return .ready(ResourcePackage(kind: .file, source: file, name: (file as NSString).lastPathComponent, rootDirectory: root,
                                      items: [relative], files: Self.files(under: root), images: [], isTemplate: false))
    }

    /// 目标路径相对其 bundle 根目录的部分
    static func pathInsideBundle(_ path: String) -> String? {
        var current = path
        var components: [String] = []
        while current.count > 1 {
            if bundleExtensions.contains((current as NSString).pathExtension) {
                return components.reversed().joined(separator: "/")
            }
            components.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Asset Catalog 颜色集：读取通用（无外观变体）的颜色分量，下发给客户端构造 UIColor / NSColor
    private func prepareColorSet(_ file: String, root: String) -> ResourcePreparation {
        guard let colorset = Self.enclosingDirectory(of: file, withExtension: "colorset"),
              let data = FileManager.default.contents(atPath: "\(colorset)/Contents.json"),
              let contents = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = contents["colors"] as? [[String: Any]] else {
            return .failed("无法解析颜色集的 Contents.json")
        }
        let name = Self.assetName(ofImageSet: colorset)
        // 暗色 / 高对比度等外观变体运行时无法替换，只取通用的那一项
        guard let entry = entries.first(where: { $0["appearances"] == nil }),
              let color = entry["color"] as? [String: Any],
              let components = color["components"] as? [String: Any] else {
            return .skipped("颜色集 \(name) 没有可热重载的通用颜色（外观变体需重新运行 App）")
        }
        func component(_ key: String) -> Double? {
            if let text = components[key] as? String {
                if text.lowercased().hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) {
                    return Double(value) / 255
                }
                return Double(text)
            }
            return components[key] as? Double
        }
        var values: [String: Double] = [:]
        if let white = component("white") {
            values = ["red": white, "green": white, "blue": white]
        } else if let red = component("red"), let green = component("green"), let blue = component("blue") {
            values = ["red": red, "green": green, "blue": blue]
        } else {
            return .failed("颜色集 \(name) 的颜色分量无法识别")
        }
        values["alpha"] = component("alpha") ?? 1
        // 色彩空间：0 = sRGB（含灰度），1 = Display P3
        values["p3"] = (color["color-space"] as? String) == "display-p3" ? 1 : 0
        return .ready(ResourcePackage(kind: .colorset, source: file, name: name, rootDirectory: root,
                                      items: [], files: [], images: [], isTemplate: false, color: values))
    }

    // MARK: - storyboard / xib

    private func compileInterface(file: String,
                                  root: String,
                                  commands: ParsedCommands,
                                  platform: Platform) -> ResourcePreparation {
        // 界面文件只属于一个平台（targetRuntime），不下发给另一平台的 App
        if let runtime = Self.targetRuntime(of: file) {
            let isMacDocument = runtime.hasPrefix("MacOSX")
            if isMacDocument != (platform.name == "macosx") {
                return .skipped("界面文件属于 \(runtime)，与该 App 的平台不符")
            }
        }
        let isStoryboard = file.hasSuffix(".storyboard")
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let item = Self.localizedPrefix(of: file) + name + (isStoryboard ? ".storyboardc" : ".nib")
        let output = "\(root)/\(item)"
        try? FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)

        let arguments = ibtoolArguments(for: file, commands: commands, platform: platform) + ["--compile", output, file]
        // ibtool 首次运行要拉起 ibtoold 守护进程，较慢；限时 120 秒，防止卡住引擎队列
        let result = Shell.run("/usr/bin/xcrun", ["ibtool"] + arguments,
                               workingDirectory: (file as NSString).deletingLastPathComponent, timeout: 120)
        let combined = result.stdout + result.stderr
        let errors = combined.components(separatedBy: "\n").filter { $0.contains(": error:") }
        guard result.succeeded, errors.isEmpty, FileManager.default.fileExists(atPath: output) else {
            let message = errors.isEmpty ? combined.trimmingCharacters(in: .whitespacesAndNewlines) : errors.prefix(10).joined(separator: "\n")
            Diagnostics.shared.failure(stage: "ibtool", file: file, summary: message.isEmpty ? "未生成产物" : message,
                                       command: ["/usr/bin/xcrun", "ibtool"] + arguments,
                                       workingDirectory: (file as NSString).deletingLastPathComponent, output: combined)
            return .failed("ibtool 编译失败：\(message.isEmpty ? "未生成产物" : message)")
        }
        return .ready(ResourcePackage(kind: isStoryboard ? .storyboard : .nib,
                                      source: file,
                                      name: name,
                                      rootDirectory: root,
                                      items: [item],
                                      files: Self.files(under: root),
                                      images: [],
                                      isTemplate: false))
    }

    /// 读取界面文件头部的 targetRuntime，如 iOS.CocoaTouch、MacOSX.Cocoa
    static func targetRuntime(of file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else {
            return nil
        }
        defer {
            try? handle.close()
        }
        guard let head = String(data: handle.readData(ofLength: 1024), encoding: .utf8),
              let range = head.range(of: "targetRuntime=\"") else {
            return nil
        }
        let rest = head[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else {
            return nil
        }
        return String(rest[..<end])
    }

    /// ibtool 参数：优先沿用构建日志里该文件的命令（含 --module、--target-device 等），否则按平台推断
    private func ibtoolArguments(for file: String, commands: ParsedCommands, platform: Platform) -> [String] {
        if let logged = commands.ibtoolCommand(for: file) {
            // 去掉可执行文件、输入文件和各类输出路径，只保留编译选项
            let dropWithValue: Set<String> = [
                "--compile", "--compilation-directory", "--output-partial-info-plist",
                "--link", "--export-dependency-info", "--write",
            ]
            var result: [String] = []
            var i = 1
            while i < logged.tokens.count {
                let token = logged.tokens[i]
                if dropWithValue.contains(token) {
                    i += 2
                    continue
                }
                if token.hasSuffix(".storyboard") || token.hasSuffix(".xib") {
                    i += 1
                    continue
                }
                result.append(token)
                i += 1
            }
            return result
        }

        var result = ["--errors", "--warnings", "--output-format", "human-readable-text"]
        // Swift 类在界面文件中多为"继承自 target 的模块"，编译时必须告知模块名
        let module = nearestSwiftModule(for: file, commands: commands, platform: platform)
        if let moduleName = module?.moduleName {
            result.append(contentsOf: ["--module", moduleName])
        }
        if platform.name == "macosx" {
            result.append(contentsOf: ["--target-device", "mac"])
        } else {
            result.append(contentsOf: ["--target-device", "iphone", "--target-device", "ipad"])
        }
        if let version = Self.deploymentTarget(from: module?.target) {
            result.append(contentsOf: ["--minimum-deployment-target", version])
        }
        return result
    }

    /// 源文件目录与界面文件最接近的 Swift 模块
    private func nearestSwiftModule(for file: String, commands: ParsedCommands, platform: Platform) -> RawCompileCommand? {
        let canonical = ParsedCommands.canonicalPath(file)
        var best: (module: RawCompileCommand, depth: Int)? = nil
        for module in commands.swiftModules(for: platform.name, arch: platform.arch) {
            let depth = ParsedCommands.swiftSources(of: module)
                .map { ParsedCommands.commonDirectoryDepth(ParsedCommands.canonicalPath($0), canonical) }
                .max() ?? 0
            if best == nil || depth > best!.depth {
                best = (module, depth)
            }
        }
        return best?.module
    }

    /// 从 -target 三元组中取最低系统版本，如 arm64-apple-ios15.0-simulator → 15.0
    static func deploymentTarget(from target: String?) -> String? {
        guard let target else {
            return nil
        }
        let parts = target.split(separator: "-")
        guard parts.count >= 3 else {
            return nil
        }
        let os = String(parts[2])
        let version = os.drop { !$0.isNumber }
        return version.isEmpty ? nil : String(version)
    }

    // MARK: - 图片

    /// 散落在工程里的图片文件：连同同目录下同名的其他倍率一起下发
    private func prepareLooseImage(_ file: String, root: String) -> ResourcePreparation {
        let fm = FileManager.default
        let directory = (file as NSString).deletingLastPathComponent
        let changed = Self.parseImageFileName((file as NSString).lastPathComponent)
        let prefix = Self.localizedPrefix(of: file)

        var items: [String] = []
        var images: [[String: Any]] = []
        let siblings = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        for sibling in siblings.sorted() {
            let parsed = Self.parseImageFileName(sibling)
            guard parsed.name == changed.name, parsed.ext == changed.ext else {
                continue
            }
            let item = prefix + sibling
            let destination = "\(root)/\(item)"
            try? fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard Self.copyBytes(from: "\(directory)/\(sibling)", to: destination) else {
                continue
            }
            items.append(item)
            images.append(["path": item, "scale": parsed.scale, "idiom": parsed.idiom])
        }
        guard !images.isEmpty else {
            return .failed("无法读取图片：\(file)")
        }
        return .ready(ResourcePackage(kind: .image, source: file, name: changed.name, rootDirectory: root,
                                      items: items, files: Self.files(under: root), images: images, isTemplate: false))
    }

    /// Asset Catalog 图片集：按 Contents.json 下发所有位图变体（暗色等外观变体暂不处理）
    private func prepareImageSet(_ imageset: String, source: String, root: String, platform: Platform) -> ResourcePreparation {
        let fm = FileManager.default
        let contentsPath = "\(imageset)/Contents.json"
        guard let data = fm.contents(atPath: contentsPath),
              let contents = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("无法解析 \(contentsPath)")
        }
        let name = Self.assetName(ofImageSet: imageset)
        let properties = contents["properties"] as? [String: Any] ?? [:]
        let isTemplate = (properties["template-rendering-intent"] as? String) == "template"
        let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp"]

        var images: [[String: Any]] = []
        let entries = contents["images"] as? [[String: Any]] ?? []
        for entry in entries {
            guard let filename = entry["filename"] as? String,
                  rasterExtensions.contains((filename as NSString).pathExtension.lowercased()),
                  entry["appearances"] == nil else {
                continue
            }
            let idiom = entry["idiom"] as? String ?? "universal"
            // 只下发当前平台可能用到的变体
            if platform.name == "macosx" ? !["universal", "mac"].contains(idiom) : idiom == "mac" {
                continue
            }
            let scaleText = (entry["scale"] as? String ?? "1x").replacingOccurrences(of: "x", with: "")
            let scale = Double(scaleText) ?? 1
            let item = "NoCompileAssets/\(name)/\(filename)"
            let destination = "\(root)/\(item)"
            try? fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard Self.copyBytes(from: "\(imageset)/\(filename)", to: destination) else {
                continue
            }
            images.append(["path": item, "scale": scale, "idiom": idiom])
        }
        guard !images.isEmpty else {
            return .failed("图片集 \(name) 中没有可热重载的位图（矢量 PDF / SVG 与外观变体需重新运行 App）")
        }
        // 图片集里的图片不在 bundle 中，不需要覆盖 bundle 条目
        return .ready(ResourcePackage(kind: .image, source: source, name: name, rootDirectory: root,
                                      items: [], files: Self.files(under: root), images: images, isTemplate: isTemplate))
    }

    /// 图片集在代码中的名字：去掉扩展名，并带上开启了 provides-namespace 的上级文件夹前缀
    static func assetName(ofImageSet imageset: String) -> String {
        var name = ((imageset as NSString).lastPathComponent as NSString).deletingPathExtension
        var directory = (imageset as NSString).deletingLastPathComponent
        while !directory.hasSuffix(".xcassets"), directory.count > 1 {
            if let data = FileManager.default.contents(atPath: "\(directory)/Contents.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let properties = json["properties"] as? [String: Any],
               properties["provides-namespace"] as? Bool == true {
                name = "\((directory as NSString).lastPathComponent)/\(name)"
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return name
    }

    /// 拆分图片文件名：icon@2x~ipad.png → (icon, 2, ipad, png)
    static func parseImageFileName(_ fileName: String) -> (name: String, scale: Double, idiom: String, ext: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var base = (fileName as NSString).deletingPathExtension
        var idiom = "universal"
        if let range = base.range(of: "~", options: .backwards) {
            let suffix = String(base[range.upperBound...])
            idiom = suffix == "ipad" ? "ipad" : (suffix == "iphone" ? "iphone" : idiom)
            base = String(base[..<range.lowerBound])
        }
        var scale = 1.0
        if let range = base.range(of: "@", options: .backwards), base[range.upperBound...].hasSuffix("x"),
           let value = Double(base[range.upperBound...].dropLast()) {
            scale = value
            base = String(base[..<range.lowerBound])
        }
        return (base, scale, idiom, ext)
    }

    // MARK: - 工具

    /// 按字节拷贝源文件。不用 FileManager.copyItem：APFS 上它会克隆文件，源文件随之收到事件，
    /// 被文件监听当成改动，形成"下发资源 → 克隆 → 再下发"的循环
    static func copyBytes(from source: String, to destination: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: source) else {
            return false
        }
        return FileManager.default.createFile(atPath: destination, contents: data)
    }

    /// 文件直接位于 xx.lproj 目录下时，返回 "xx.lproj/"
    static func localizedPrefix(of file: String) -> String {
        let parent = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.hasSuffix(".lproj") ? parent + "/" : ""
    }

    /// 向上查找扩展名为 ext 的目录
    static func enclosingDirectory(of file: String, withExtension ext: String) -> String? {
        var directory = (file as NSString).deletingLastPathComponent
        while directory.count > 1 {
            if (directory as NSString).pathExtension == ext {
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 递归列出目录下的所有普通文件（相对路径）
    static func files(under root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return []
        }
        var result: [String] = []
        while let relative = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(root)/\(relative)", isDirectory: &isDirectory), !isDirectory.boolValue {
                result.append(relative)
            }
        }
        return result.sorted()
    }
}
