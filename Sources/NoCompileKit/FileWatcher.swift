//
//  FileWatcher.swift
//  基于 FSEvents 监听源码目录，源文件保存后触发回调。
//  Xcode 保存文件是原子 rename，这里只关注 rename / modified 事件。
//

import Foundation
import CoreServices

public final class FileWatcher {

    /// 关注的源文件扩展名
    public static let watchedExtensions: Set<String> = ["m", "mm", "c", "cpp", "cc", "cxx", "swift", "h", "hpp"]

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
            let ext = (path as NSString).pathExtension.lowercased()
            guard Self.watchedExtensions.contains(ext) else {
                continue
            }
            if path.contains("/DerivedData/") || path.contains("/.git/") || (path as NSString).lastPathComponent.hasPrefix(".") {
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
