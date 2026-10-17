//
//  A13SwiftAsync.swift
//  场景 A13：async / await、actor、Task。async 函数会被拆成多个 continuation 函数
//

import Foundation

actor A13Counter {
    private var value = 0

    func bump() -> Int {
        value += 1
        return value
    }
}

func a13Fetch() async -> String {
    try? await Task.sleep(nanoseconds: 1_000_000)
    return "A13(@@v1@@)"
}

enum A13 {
    static let counter = A13Counter()

    /// 在后台线程同步等待 async 结果（probe 在后台队列执行）
    static func probe() -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "timeout"
        Task.detached {
            let text = await a13Fetch()
            let n = await counter.bump()
            result = "\(text) n=\(n)"
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }
}
