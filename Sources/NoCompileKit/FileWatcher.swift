//
//  FileWatcher.swift
//  基于 FSEvents 监听源码目录，源文件与界面 / 图片资源保存后触发回调。
//  Xcode 保存文件是原子 rename，这里关注 rename / modified / created 事件（created 覆盖新增文件）。
//
//  git pull / merge / 切分支会在极短时间内改动一批文件（还伴随 .git 下成千上万个对象文件），
//  因此：
//  1. 事件先攒批：最后一个事件之后安静一小段时间（或累计等待达到上限）再统一回调，
//     让一次 git 操作只触发一次注入；
//  2. 事件过多时 FSEvents 会丢弃单个文件事件，只给出"需重新扫描某目录"的标记，
//     此时按修改时间重新扫描该目录，补回被合并掉的改动。
//

import Foundation
import CoreServices

public final class FileWatcher {

    /// 关注的源文件扩展名
    public static let sourceExtensions: Set<String> = ["m", "mm", "c", "cpp", "cc", "cxx", "swift", "h", "hpp", "pch"]
    /// 关注的资源文件扩展名：界面文件与位图（xcassets 中的 Contents.json 单独判断）
    public static let resourceExtensions: Set<String> = [
        "storyboard", "xib", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
        // 原样拷贝进 bundle 的资源：只有构建日志里确认是资源拷贝目标的文件才会下发，其余忽略
        "strings", "stringsdict", "json", "plist", "txt", "xml", "html", "css", "js", "csv", "yaml", "yml",
        "mp3", "wav", "m4a", "aac", "caf", "mp4", "mov", "ttf", "otf", "pdf", "sqlite", "db", "dat", "bin", "lottie",
    ]
    /// 工程结构文件：变化后需要重新计算监听目录（如新增了本地 Pod）
    public static let projectStructureFiles: Set<String> = ["Podfile.lock", "contents.xcworkspacedata"]

    /// 是否为需要关注的文件
    public static func isWatched(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if sourceExtensions.contains(ext) || resourceExtensions.contains(ext) {
            return true
        }
        if projectStructureFiles.contains((path as NSString).lastPathComponent) {
            return true
        }
        // 图片集 / 颜色集的描述文件变化（如修改 scale、渲染模式、颜色分量）也需要重新下发
        return ext == "json" && (path.contains(".imageset/") || path.contains(".colorset/"))
    }

    /// 是否为工程结构文件
    public static func isProjectStructureFile(_ path: String) -> Bool {
        return projectStructureFiles.contains((path as NSString).lastPathComponent)
    }

    /// 路径是否位于不需要关注的目录（构建产物、版本库、编辑器临时文件等）
    static func isIgnored(_ path: String) -> Bool {
        if path.contains("/DerivedData/") || path.contains("/.git/") {
            return true
        }
        // 构建产物里的资源（工程目录下的 .app、编译后的 nib 等）不是源文件
        if path.contains(".app/") || path.contains(".xcarchive/") || path.contains(".storyboardc/") || path.contains(".nib/") {
            return true
        }
        // 编辑器保存时产生的临时 / 备份文件：如 Xcode 的 "Foo~.m"、隐藏文件、".sb-xxxx" 安全保存文件
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") || name.contains("~") || name.contains(".sb-") {
            return true
        }
        return false
    }

    /// 重新扫描时跳过的目录名
    private static let skippedDirectoryNames: Set<String> = [".git", "DerivedData", "build", ".build", "node_modules", ".svn"]

    private var stream: FSEventStreamRef?
    public let directories: [String]
    private let onChange: ([String]) -> Void
    private let callbackQueue = DispatchQueue(label: "com.nocompile.filewatcher")
    private var lastFire: [String: Date] = [:]
    private let debounce: TimeInterval
    /// 攒批：最后一个事件后安静这么久再回调
    private let quietInterval: TimeInterval
    /// 攒批：从第一个事件起最多等待这么久
    private let maxBatchDelay: TimeInterval
    private var batch: [String] = []
    private var batchSet = Set<String>()
    private var batchStart: Date?
    private var flushWork: DispatchWorkItem?
    /// 上一次处理事件的时间，重新扫描时以此为界找出新改动的文件
    private var lastEventDate = Date()

    public init(directories: [String], debounce: TimeInterval = 0.3,
                quietInterval: TimeInterval = 0.4, maxBatchDelay: TimeInterval = 3,
                onChange: @escaping ([String]) -> Void) {
        self.directories = directories
        self.onChange = onChange
        self.debounce = debounce
        self.quietInterval = quietInterval
        self.maxBatchDelay = maxBatchDelay
    }

    @discardableResult
    public func start() -> Bool {
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
            var rescan: [String] = []
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                | UInt32(kFSEventStreamEventFlagUserDropped)
                | UInt32(kFSEventStreamEventFlagKernelDropped)
            for i in 0 ..< count {
                guard let path = pathsPtr[i] as? String else { continue }
                let flag = flags[i]
                if (flag & rescanFlags) != 0 {
                    rescan.append(path)
                    continue
                }
                // 文件被克隆（APFS clonefile，拷贝资源到暂存目录时就会发生）时，源文件也会收到带 Renamed 位的
                // Cloned 事件，但内容并没有变化。若把它当成改动，会形成"下发资源 → 克隆源文件 → 再下发"的死循环
                let cloned = (flag & UInt32(kFSEventStreamEventFlagItemCloned)) != 0
                let interesting = ((flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 && !cloned)
                    || (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                    || (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                if interesting {
                    changed.append(path)
                }
            }
            if !rescan.isEmpty {
                watcher.rescan(rescan)
            }
            if !changed.isEmpty {
                watcher.handle(changed)
            }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            Diagnostics.shared.log("监听", "FSEventStreamCreate 失败：\(directories)", level: .error)
            return false
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        guard FSEventStreamStart(stream) else {
            Diagnostics.shared.log("监听", "FSEventStreamStart 失败：\(directories)", level: .error)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        Diagnostics.shared.log("监听", "开始监听：\(directories.joined(separator: "、"))")
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackQueue.sync {
            flushWork?.cancel()
            flushWork = nil
            batch.removeAll()
            batchSet.removeAll()
        }
    }

    // MARK: - 事件处理（均在 callbackQueue 上）

    private func handle(_ paths: [String]) {
        let now = Date()
        lastEventDate = now
        var accepted: [String] = []
        for path in paths {
            guard Self.isWatched(path), !Self.isIgnored(path) else {
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
        enqueue(accepted)
    }

    /// FSEvents 丢弃了单个文件事件：扫描目录，找出上次事件之后修改过的文件
    private func rescan(_ directories: [String]) {
        let since = lastEventDate.addingTimeInterval(-2)
        lastEventDate = Date()
        var found: [String] = []
        let fm = FileManager.default
        var visited = 0
        for directory in Set(directories) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }
            while let item = enumerator.nextObject() as? URL {
                visited += 1
                // 防御：超大目录只扫描有限数量的条目
                if visited > 300_000 {
                    break
                }
                let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if Self.skippedDirectoryNames.contains(item.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let path = item.path
                guard Self.isWatched(path), !Self.isIgnored(path),
                      let modified = values?.contentModificationDate, modified >= since else {
                    continue
                }
                found.append(path)
            }
        }
        Diagnostics.shared.log("监听", "FSEvents 合并了事件，重新扫描 \(directories.count) 个目录（\(visited) 项），找回 \(found.count) 个改动",
                               level: .warning)
        enqueue(found)
    }

    private func enqueue(_ paths: [String]) {
        guard !paths.isEmpty else {
            return
        }
        for path in paths where batchSet.insert(path).inserted {
            batch.append(path)
        }
        let now = Date()
        if batchStart == nil {
            batchStart = now
        }
        flushWork?.cancel()
        // 安静 quietInterval 后回调；但从第一个事件起最多等 maxBatchDelay，避免持续写入时一直不触发
        let waited = now.timeIntervalSince(batchStart ?? now)
        let delay = max(0, min(quietInterval, maxBatchDelay - waited))
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWork = work
        callbackQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flush() {
        let paths = batch
        batch.removeAll()
        batchSet.removeAll()
        batchStart = nil
        flushWork = nil
        // 清理过期的防抖记录，避免长时间运行后无限增长
        if lastFire.count > 5000 {
            let cutoff = Date().addingTimeInterval(-60)
            lastFire = lastFire.filter { $0.value > cutoff }
        }
        guard !paths.isEmpty else {
            return
        }
        if paths.count > 1 {
            Diagnostics.shared.log("监听", "一批改动 \(paths.count) 个文件：\(paths.prefix(20).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))\(paths.count > 20 ? " …" : "")")
        } else {
            Diagnostics.shared.log("监听", "改动：\(paths[0])", level: .debug)
        }
        onChange(paths)
    }
}
