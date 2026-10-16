//
//  FileWatcher.swift
//  基于 FSEvents 监听源码目录，源文件与界面 / 图片资源保存后触发回调。
//  Xcode 保存文件是原子 rename，这里关注 rename / modified / created 事件（created 覆盖新增文件）。
//

import Foundation
import CoreServices

public final class FileWatcher {

    /// 关注的源文件扩展名
    public static let sourceExtensions: Set<String> = ["m", "mm", "c", "cpp", "cc", "cxx", "swift", "h", "hpp"]
    /// 关注的资源文件扩展名：界面文件与位图（xcassets 中的 Contents.json 单独判断）
    public static let resourceExtensions: Set<String> = ["storyboard", "xib", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp"]

    /// 是否为需要关注的文件
    public static func isWatched(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if sourceExtensions.contains(ext) || resourceExtensions.contains(ext) {
            return true
        }
        // 图片集的描述文件变化（如修改 scale、渲染模式）也需要重新下发
        return ext == "json" && path.contains(".imageset/")
    }

    private var stream: FSEventStreamRef?
    private let directories: [String]
    private let onChange: ([String]) -> Void
    private let callbackQueue = DispatchQueue(label: "com.nocompile.filewatcher")
    private var lastFire: [String: Date] = [:]
    private let debounce: TimeInterval

    public init(directories: [String], debounce: TimeInterval = 0.3, onChange: @escaping ([String]) -> Void) {
        self.directories = directories
        self.onChange = onChange
        self.debounce = debounce
    }

    public func start() {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let paths = directories as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault,
                                               { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathsPtr = unsafeBitCast(paths, to: NSArray.self)
            var changed: [String] = []
            for i in 0 ..< count {
                guard let path = pathsPtr[i] as? String else { continue }
                let flag = flags[i]
                let interesting = (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                    || (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                    || (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                if interesting {
                    changed.append(path)
                }
            }
            if !changed.isEmpty {
                watcher.handle(changed)
            }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        let now = Date()
        var accepted: [String] = []
        for path in paths {
            guard Self.isWatched(path) else {
                continue
            }
            if path.contains("/DerivedData/") || path.contains("/.git/") {
                continue
            }
            // 构建产物里的资源（工程目录下的 .app、编译后的 nib 等）不是源文件
            if path.contains(".app/") || path.contains(".xcarchive/") || path.contains(".storyboardc/") || path.contains(".nib/") {
                continue
            }
            // 编辑器保存时产生的临时 / 备份文件：如 Xcode 的 "Foo~.m"、隐藏文件、".sb-xxxx" 安全保存文件
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") || name.contains("~") || name.contains(".sb-") {
                continue
            }
            // 只处理当前确实存在的文件（原子保存时旧路径会先被移走）
            if !FileManager.default.fileExists(atPath: path) {
                continue
            }
            if let last = lastFire[path], now.timeIntervalSince(last) < debounce {
                continue
            }
            lastFire[path] = now
            accepted.append(path)
        }
        if !accepted.isEmpty {
            onChange(accepted)
        }
    }
}
