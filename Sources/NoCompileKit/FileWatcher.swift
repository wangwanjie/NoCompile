//
//  FileWatcher.swift
//  监听源码目录，源文件与界面 / 图片资源内容变化后触发回调。
//
//  两路来源，统一按「文件指纹」判定是否真的改了：
//  1. FSEvents：Xcode 原子保存、git 操作等都会产生事件，但事件标志并不可靠——
//     一次保存可能同时带 Renamed / Cloned / Modified，克隆、改扩展属性也会产生事件。
//     因此不再按标志位猜测，收到事件后重新 stat 文件，修改时间、大小、inode 任一变化才算改动，
//     并比较内容摘要，内容没变（touch、克隆、原样重写）的不触发。
//  2. 扫描：启动时遍历一次监听目录建立指纹基线；之后只在用户手动「检查改动」或 FSEvents 报告丢弃了事件时
//     重新遍历，与基线比较，补回 FSEvents 漏掉的改动（目录权限、网络盘、事件被合并丢弃等情况）。不做定时轮询。
//
//  git pull / merge / 切分支会在极短时间内改动一批文件，事件先攒批：最后一个事件之后安静一小段时间
//  （或累计等待达到上限）再统一回调，让一次 git 操作只触发一次注入。
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
        return projectStructureFiles.contains((path as NSString).lastPathComponent)
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

    /// 主动扫描时跳过的目录名（隐藏目录一律跳过）
    private static let skippedDirectoryNames: Set<String> = ["DerivedData", "build", "node_modules", "xcuserdata", "Carthage"]
    /// 主动扫描时跳过的目录扩展名：构建产物与工程包，不含源文件
    private static let skippedDirectoryExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "app", "appex", "framework", "xcframework", "dSYM",
        "xcarchive", "storyboardc", "nib", "momd", "xcresult", "playground",
    ]
    /// 计算内容摘要的文件大小上限，更大的文件只比较指纹
    private static let maxDigestSize: Int64 = 8 * 1024 * 1024

    /// 文件指纹：修改时间（纳秒精度）、大小与 inode
    struct Stamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
        let size: Int64
        let inode: UInt64

        init(_ st: stat) {
            seconds = Int(st.st_mtimespec.tv_sec)
            nanoseconds = Int(st.st_mtimespec.tv_nsec)
            size = Int64(st.st_size)
            inode = UInt64(st.st_ino)
        }

        var modificationDate: Date {
            return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
        }
    }

    /// 已知文件的最新状态。digest 为内容摘要，只在文件变化后计算（首次扫描只记录指纹，避免读全部文件）
    private struct Entry {
        var stamp: Stamp
        var digest: UInt64?
    }

    public let directories: [String]
    private let onChange: ([String]) -> Void
    /// 所有状态都只在 queue 上访问；FSEvents 回调也投递到这里
    private let queue = DispatchQueue(label: "com.nocompile.filewatcher")
    /// 目录遍历在单独的队列上执行，不阻塞事件处理
    private let scanQueue = DispatchQueue(label: "com.nocompile.filewatcher.scan", qos: .utility)
    private var stream: FSEventStreamRef?
    private var running = false
    private var entries: [String: Entry] = [:]
    /// 首次全量扫描完成后才能把「不认识的文件」判定为新增文件
    private var baselineReady = false
    private var scanInFlight = false
    /// 扫描进行中又收到了扫描请求（如手动检查、FSEvents 要求重新扫描），本次结束后立即再扫一次
    private var rescanRequested = false
    /// 手动检查的回调：下一次扫描合并完成后调用，参数为找到的改动数
    private var manualCompletions: [(Int) -> Void] = []

    /// 攒批：最后一个事件后安静这么久再回调
    private let quietInterval: TimeInterval
    /// 攒批：从第一个事件起最多等待这么久
    private let maxBatchDelay: TimeInterval
    private var batch: [String] = []
    private var batchSet = Set<String>()
    private var batchStart: Date?
    private var flushWork: DispatchWorkItem?

    public init(directories: [String], quietInterval: TimeInterval = 0.35, maxBatchDelay: TimeInterval = 3,
                onChange: @escaping ([String]) -> Void) {
        // FSEvents 报告的是解析过符号链接的真实路径（如 /tmp → /private/tmp），扫描也必须用真实路径，
        // 否则同一个文件会以两种路径各记一份指纹，被当成两个文件重复触发
        self.directories = directories.map { directory in
            guard let resolved = realpath(directory, nil) else {
                return directory
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        self.onChange = onChange
        self.quietInterval = quietInterval
        self.maxBatchDelay = maxBatchDelay
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 开始监听，返回值表示 FSEvents 是否可用（不可用时仍可手动检查改动）
    @discardableResult
    public func start() -> Bool {
        let eventsOK = startEventStream()
        // 基线扫描：记录所有文件的指纹，之后的事件与手动检查都与它比较
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.requestScan()
        }
        Diagnostics.shared.log("监听", "开始监听：\(directories.joined(separator: "、"))")
        return eventsOK
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        queue.sync {
            running = false
            flushWork?.cancel()
            flushWork = nil
            batch.removeAll()
            batchSet.removeAll()
            let completions = manualCompletions
            manualCompletions.removeAll()
            completions.forEach { $0(0) }
        }
    }

    /// 立即扫描一次监听目录，找出 FSEvents 漏掉的改动。completion 在内部队列回调，参数为找到的改动数
    public func checkNow(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self, self.running else {
                completion(0)
                return
            }
            self.manualCompletions.append(completion)
            self.requestScan()
        }
    }

    // MARK: - FSEvents

    private func startEventStream() -> Bool {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathsArray = unsafeBitCast(paths, to: NSArray.self)
            var changed: [String] = []
            var needsScan = false
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                | UInt32(kFSEventStreamEventFlagUserDropped)
                | UInt32(kFSEventStreamEventFlagKernelDropped)
            for i in 0 ..< count {
                guard let path = pathsArray[i] as? String else { continue }
                if (flags[i] & rescanFlags) != 0 {
                    needsScan = true
                    continue
                }
                // 只关心文件本身的事件，目录事件交给扫描
                if (flags[i] & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0 {
                    continue
                }
                changed.append(path)
            }
            // 回调本身就在 queue 上（见 FSEventStreamSetDispatchQueue）
            if needsScan {
                Diagnostics.shared.log("监听", "FSEvents 合并或丢弃了事件，重新扫描监听目录", level: .warning)
                watcher.requestScan()
            }
            if !changed.isEmpty {
                watcher.consider(changed)
            }
        }, &context, directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            Diagnostics.shared.log("监听", "FSEventStreamCreate 失败：\(directories)", level: .error)
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            Diagnostics.shared.log("监听", "FSEventStreamStart 失败：\(directories)", level: .error)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    // MARK: - 变化判定（均在 queue 上）

    /// 逐个检查候选路径，内容确实变化的加入批次
    private func consider(_ paths: [String]) {
        guard running else {
            return
        }
        let recentLimit = Date().addingTimeInterval(-600)
        var accepted: [String] = []
        for path in paths where Self.isWatched(path) && !Self.isIgnored(path) {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                // 已删除或不是普通文件（原子保存时旧路径会先被移走）
                entries[path] = nil
                continue
            }
            let stamp = Stamp(st)
            let previous = entries[path]
            if previous?.stamp == stamp {
                // 指纹没变：克隆、改扩展属性、重复事件
                continue
            }
            let digest = stamp.size <= Self.maxDigestSize ? Self.digest(ofFile: path) : nil
            entries[path] = Entry(stamp: stamp, digest: digest)
            if let previous {
                // 指纹变了但内容相同（touch、原样重写），不算改动
                if let digest, let old = previous.digest, digest == old {
                    continue
                }
                accepted.append(path)
            } else if baselineReady || stamp.modificationDate >= recentLimit {
                // 基线里没有的文件：基线已建立说明是新增文件；基线还没建好时只接受最近修改过的
                accepted.append(path)
            }
        }
        enqueue(accepted)
    }

    /// 文件内容摘要（FNV-1a 64），读取失败返回 nil
    private static func digest(ofFile path: String) -> UInt64? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    // MARK: - 扫描

    /// 请求尽快扫描一次（在 queue 上调用）
    private func requestScan() {
        guard running else {
            return
        }
        if scanInFlight {
            rescanRequested = true
            return
        }
        runScan()
    }

    private func runScan() {
        scanInFlight = true
        let roots = directories
        scanQueue.async { [weak self] in
            let start = Date()
            let scanned = Self.scan(roots: roots)
            let duration = Date().timeIntervalSince(start)
            self?.queue.async {
                self?.finishScan(scanned, duration: duration)
            }
        }
    }

    private func finishScan(_ scanned: [String: Stamp], duration: TimeInterval) {
        scanInFlight = false
        guard running else {
            return
        }
        var found = 0
        if !baselineReady {
            // 基线：只记录指纹。扫描期间事件已登记过的文件保留事件里的最新状态
            for (path, stamp) in scanned where entries[path] == nil {
                entries[path] = Entry(stamp: stamp, digest: nil)
            }
            baselineReady = true
            Diagnostics.shared.log("监听", "建立文件基线：\(scanned.count) 个文件，耗时 \(String(format: "%.2f", duration))s")
            // 基线建好前就请求了手动检查：基线本身不产生改动，再扫一次才能比较
            if !manualCompletions.isEmpty {
                rescanRequested = true
            }
        } else {
            var candidates: [String] = []
            for (path, stamp) in scanned where entries[path]?.stamp != stamp {
                candidates.append(path)
            }
            // 扫描里消失的文件：再确认一次确实不存在后移除
            for path in entries.keys where scanned[path] == nil && access(path, F_OK) != 0 {
                entries[path] = nil
            }
            let before = batch.count
            consider(candidates)
            found = batch.count - before
            if found > 0 {
                Diagnostics.shared.log("监听", "扫描发现 \(found) 个 FSEvents 未报告的改动", level: .warning)
            }
            let completions = manualCompletions
            manualCompletions.removeAll()
            completions.forEach { $0(found) }
        }
        if rescanRequested {
            rescanRequested = false
            runScan()
        }
    }

    /// 遍历监听目录，返回所有关注文件的指纹
    private static func scan(roots: [String]) -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        for root in roots {
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
            defer { free(argv[0]) }
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                continue
            }
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                let path = String(cString: entry.pointee.fts_path)
                if info == FTS_D {
                    // 根目录本身不跳过
                    if entry.pointee.fts_level > 0 && shouldSkipDirectory(path) {
                        fts_set(fts, entry, FTS_SKIP)
                    }
                    continue
                }
                guard info == FTS_F, let statPointer = entry.pointee.fts_statp,
                      isWatched(path), !isIgnored(path) else {
                    continue
                }
                result[path] = Stamp(statPointer.pointee)
            }
            fts_close(fts)
        }
        return result
    }

    private static func shouldSkipDirectory(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") || skippedDirectoryNames.contains(name) {
            return true
        }
        return skippedDirectoryExtensions.contains((name as NSString).pathExtension)
    }

    // MARK: - 攒批

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
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flush() {
        let paths = batch
        batch.removeAll()
        batchSet.removeAll()
        batchStart = nil
        flushWork = nil
        guard running, !paths.isEmpty else {
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
