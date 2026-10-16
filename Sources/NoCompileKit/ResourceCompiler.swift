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

    /// 下发给客户端的描述（不含文件内容）
    public var json: [String: Any] {
        return [
            "kind": kind.rawValue,
            "source": source,
            "name": name,
            "items": items,
            "images": images,
            "template": isTemplate,
        ]
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
            if let imageset = Self.enclosingDirectory(of: file, withExtension: "imageset") {
                return prepareImageSet(imageset, source: file, root: root, platform: platform)
            }
            if file.contains(".xcassets/") || ext == "json" {
                // App 图标、颜色等其他 Asset Catalog 条目：运行时无法替换
                return .skipped("App 图标、颜色等 Asset Catalog 条目运行时无法替换，需重新运行 App")
            }
            return prepareLooseImage(file, root: root)
        }
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
        let result = Shell.run("/usr/bin/xcrun", ["ibtool"] + arguments,
                               workingDirectory: (file as NSString).deletingLastPathComponent)
        let combined = result.stdout + result.stderr
        let errors = combined.components(separatedBy: "\n").filter { $0.contains(": error:") }
        guard result.succeeded, errors.isEmpty, FileManager.default.fileExists(atPath: output) else {
            let message = errors.isEmpty ? combined.trimmingCharacters(in: .whitespacesAndNewlines) : errors.prefix(10).joined(separator: "\n")
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
            guard (try? fm.copyItem(atPath: "\(directory)/\(sibling)", toPath: destination)) != nil else {
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
            guard (try? fm.copyItem(atPath: "\(imageset)/\(filename)", toPath: destination)) != nil else {
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
