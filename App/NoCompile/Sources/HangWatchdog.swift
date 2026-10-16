//
//  HangWatchdog.swift
//  主线程卡顿看门狗：后台线程定时向主线程投递心跳，主线程超过阈值未响应时，
//  暂停主线程、沿帧指针链采集调用栈，写入 ~/Library/Logs/NoCompile/Hangs，随诊断包导出。
//  用户遇到"转菊花"时无需自己抓 sample，导出诊断包即可带上卡在哪里。
//
//  注意：主线程被暂停期间它可能持有 malloc 等锁，此时采集线程绝不能分配内存，
//  所以帧地址先写进预先分配好的缓冲区，恢复主线程后再做符号化与写文件。
//

import Foundation
import Darwin
import NoCompileKit

final class HangWatchdog {

    static let shared = HangWatchdog()

    /// 主线程无响应超过该时长视为卡顿
    private let threshold: TimeInterval = 2.0
    /// 心跳检查间隔
    private let interval: TimeInterval = 0.5
    /// 同一次卡顿中最多采样几次（间隔 3 秒），便于看出是否一直卡在同一处
    private let maxSamplesPerHang = 4
    private let maxFrames = 128

    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private var started = false

    private let lock = NSLock()
    /// 已投递、主线程尚未处理的心跳的投递时间
    private var pendingSince: Date?

    private init() {}

    /// 须在主线程调用
    func start() {
        precondition(Thread.isMainThread)
        guard !started else {
            return
        }
        started = true
        mainThread = mach_thread_self()
        // start() 在主线程调用，pthread_self() 即主线程
        let main = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
        let size = UInt(pthread_get_stacksize_np(main))
        stackHigh = top
        stackLow = top > size ? top - size : 0
        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "com.nocompile.hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        var hangStart: Date?
        var samples: [String] = []
        var nextSample = Date.distantFuture
        while true {
            Thread.sleep(forTimeInterval: interval)
            lock.lock()
            let since = pendingSince
            lock.unlock()

            guard let since else {
                // 上一次心跳已被处理：若刚结束一次卡顿，写下报告
                if let start = hangStart {
                    report(duration: Date().timeIntervalSince(start), samples: samples)
                    hangStart = nil
                    samples.removeAll()
                }
                lock.lock()
                pendingSince = Date()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.pendingSince = nil
                    self.lock.unlock()
                }
                continue
            }

            let elapsed = Date().timeIntervalSince(since)
            guard elapsed >= threshold else {
                continue
            }
            if hangStart == nil {
                hangStart = since
                nextSample = Date()
                Diagnostics.shared.log("卡顿", "主线程已 \(String(format: "%.1f", elapsed))s 无响应，开始采集调用栈", level: .warning)
            }
            if samples.count < maxSamplesPerHang, Date() >= nextSample {
                let stack = captureMainThreadStack()
                samples.append("—— 第 \(samples.count + 1) 次采样（已卡 \(String(format: "%.1f", elapsed))s）——\n\(stack)")
                nextSample = Date().addingTimeInterval(3)
            }
        }
    }

    /// 卡顿结束后写报告；卡顿持续期间若用户强制退出，至少 Diagnostics.log 里已有开始记录
    private func report(duration: TimeInterval, samples: [String]) {
        let summary = "主线程卡顿 \(String(format: "%.1f", duration))s"
        Diagnostics.shared.log("卡顿", "\(summary)，采样 \(samples.count) 次，详见 Hangs 目录", level: .error)
        let fm = FileManager.default
        let directory = Diagnostics.shared.hangsDirectory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Diagnostics.shared.timestamp().replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = directory.appendingPathComponent("hang_\(stamp).txt")
        let text = "\(summary)\n时间：\(Diagnostics.shared.timestamp())\n\n" + samples.joined(separator: "\n\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        // 只保留最近 20 份
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in sorted.dropLast(20) {
                try? fm.removeItem(at: old)
            }
        }
    }

    /// 暂停主线程，读取寄存器并沿帧指针链收集返回地址，恢复后再符号化
    private func captureMainThreadStack() -> String {
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer {
            buffer.deallocate()
        }
        var count = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else {
            return "（无法暂停主线程）"
        }
        // ---- 主线程暂停期间：不分配内存、不加锁 ----
        var pc: UInt = 0
        var frame: UInt = 0
        var link: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if kr == KERN_SUCCESS {
            pc = UInt(state.__pc)
            frame = UInt(state.__fp)
            link = UInt(state.__lr)
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &stateCount)
            }
        }
        if kr == KERN_SUCCESS {
            pc = UInt(state.__rip)
            frame = UInt(state.__rbp)
        }
        #else
        let kr = KERN_FAILURE
        #endif
        if kr == KERN_SUCCESS {
            buffer[count] = Self.strip(pc)
            count += 1
            if link != 0 {
                buffer[count] = Self.strip(link)
                count += 1
            }
            // 帧记录：[fp] = 上一帧 fp，[fp + 8] = 返回地址。只在主线程栈范围内、地址递增时继续
            while count < maxFrames, frame != 0, frame & 0x7 == 0,
                  frame >= stackLow, frame + 16 <= stackHigh {
                guard let record = UnsafePointer<UInt>(bitPattern: frame) else {
                    break
                }
                let next = record[0]
                let returnAddress = Self.strip(record[1])
                if returnAddress == 0 {
                    break
                }
                buffer[count] = returnAddress
                count += 1
                if next <= frame {
                    break
                }
                frame = next
            }
        }
        thread_resume(mainThread)
        // ---- 主线程已恢复 ----
        guard kr == KERN_SUCCESS else {
            return "（读取主线程寄存器失败：\(kr)）"
        }
        var lines: [String] = []
        for index in 0 ..< count {
            lines.append(Self.symbolicate(buffer[index], index: index))
        }
        return lines.joined(separator: "\n")
    }

    /// 去掉 arm64e 指针认证位（用户态地址最多 47 位）
    private static func strip(_ address: UInt) -> UInt {
        return address & 0x0000_7FFF_FFFF_FFFF
    }

    private static func symbolicate(_ address: UInt, index: Int) -> String {
        var info = Dl_info()
        let prefix = String(format: "%2d  0x%016lx", index, address)
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
            return prefix
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let symbolPointer = info.dli_sname else {
            let base = UInt(bitPattern: info.dli_fbase)
            return "\(prefix)  \(image) + \(address - base)"
        }
        let symbol = String(cString: symbolPointer)
        let offset = address - UInt(bitPattern: info.dli_saddr)
        return "\(prefix)  \(image)  \(symbol) + \(offset)"
    }
}
