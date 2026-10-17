//
//  ProbeWriter.swift
//  把全部场景的当前输出周期性写成 JSON，供端到端脚本读取。
//  仅当环境变量 EXAMPLE_PROBE_FILE 存在时启用（模拟器用 SIMCTL_CHILD_EXAMPLE_PROBE_FILE 传入）
//

import Foundation

enum ProbeWriter {
    private static var timer: DispatchSourceTimer?
    private static let backgroundQueue = DispatchQueue(label: "example.probe.background", qos: .utility, attributes: .concurrent)
    private static var inflight = Set<String>()
    private static var backgroundResults: [String: String] = [:]
    private static let lock = NSLock()
    private static var tick = 0

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["EXAMPLE_PROBE_FILE"], !path.isEmpty else {
            return
        }
        let interval = Double(ProcessInfo.processInfo.environment["EXAMPLE_PROBE_INTERVAL"] ?? "") ?? 0.4
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: interval)
        source.setEventHandler {
            write(to: path)
        }
        source.resume()
        timer = source
    }

    /// 取一份全部场景的快照：主线程场景同步取，后台场景异步取并缓存上一次结果
    static func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        for scenario in ScenarioCatalog.all {
            if scenario.onMain {
                result[scenario.id] = scenario.probe()
            } else if Thread.isMainThread {
                // 非 UI 场景放到后台执行（async 场景需要阻塞等待），结果下次读取
                let id = scenario.id
                lock.lock()
                let shouldStart = !inflight.contains(id)
                if shouldStart {
                    inflight.insert(id)
                }
                result[id] = backgroundResults[id] ?? "(pending)"
                lock.unlock()
                if shouldStart {
                    backgroundQueue.async {
                        let text = scenario.probe()
                        lock.lock()
                        backgroundResults[id] = text
                        inflight.remove(id)
                        lock.unlock()
                    }
                }
            } else {
                result[scenario.id] = scenario.probe()
            }
        }
        return result
    }

    private static func write(to path: String) {
        tick += 1
        var payload: [String: Any] = ["values": snapshot()]
        payload["tick"] = tick
        payload["pid"] = ProcessInfo.processInfo.processIdentifier
        payload["time"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        // 先写临时文件再改名，避免脚本读到写了一半的 JSON
        let temp = path + ".tmp"
        try? data.write(to: URL(fileURLWithPath: temp))
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
    }
}
