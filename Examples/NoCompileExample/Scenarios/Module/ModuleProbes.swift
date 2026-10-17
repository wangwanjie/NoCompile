//
//  ModuleProbes.swift
//  跨模块场景（M 系列）的取值入口：App 通过 import 使用 ExCore / ExKit / ExNetwork / ExPlayer。
//  令牌在各模块自己的源文件里，这里不放令牌
//

import Foundation
import ExCore
import ExKit
import ExNetwork

enum ModuleProbes {
    /// M01：ExCore 的 ObjC 单例
    static func m01() -> String {
        ExLogger.shared().log("hello")
        return ExLogger.shared().describeState()
    }

    /// M02：ExCore 的 C 函数
    static func m02() -> String {
        return String(cString: ex_math_describe())
    }

    /// M03：ExKit 的 Swift 公开函数
    static func m03() -> String {
        let joined = (try? ExKit.ExFormatter.join("a", "b", separator: "-")) ?? "err"
        return ExKit.ExFormatter.format(3) + " " + joined
    }

    /// M06：ExKit 内 ObjC 调 Swift
    static func m06() -> String {
        return ExObjCUser.callSwift()
    }

    /// M11：@inlinable 对照
    static func m11() -> String {
        return ExInlinable.token() + " " + ExInlinable.plainToken()
    }

    /// M12：跨模块枚举 + property wrapper
    static func m12() -> String {
        struct Settings {
            @ExClamped(0...10) var volume = 50
        }
        var settings = Settings()
        settings.volume = 99
        return ExPlayerState.playing(track: "t", progress: 0.5).label + " vol=\(settings.volume)"
    }

    /// M13：两个模块里同名的 ExFormatter
    static func m13() -> String {
        return ExKit.ExFormatter.moduleName() + "&" + ExNetwork.ExFormatter.moduleName()
    }

    /// M14：ExCore 给系统类 NSArray 加的分类
    static func m14() -> String {
        let array: NSArray = ["a", "b"]
        let safe = array.kg_safeObject(at: 9) == nil ? "nil" : "obj"
        return array.kg_safeDescription() + " " + safe
    }

    /// M15：ExCore 的事件总线（启动时注册的通知观察者）
    static func m15() -> String {
        ExEventBus.shared().fire("e")
        return ExEventBus.shared().lastEvent
    }

    /// M16：ExCore 的 +load swizzle
    static func m16() -> String {
        return ExSwizzleTarget().describe() + " load=\(ExSwizzleTarget.loadCount())"
    }

    /// M17：ExCore 的外部常量
    static func m17() -> String {
        return ExStatusToken
    }

    /// M18：ExCore 给 NSString 加的分类
    static func m18() -> String {
        return ("/a/b/c.txt" as NSString).kg_lastPathToken()
    }

    /// M08：ExPlayer 静态库
    static func m08() -> String {
        return ExPlayerEngine.engineInfo() + " " + ExPlayerEngine.playlistSummary() + " " + ExPlayerEngine.audioMathInfo()
    }

    /// M08b：静态库里的 C++ 异常
    static func m08b() -> String {
        return ExPlayerEngine.exceptionInfo()
    }

    /// H07：静态库里的头文件模板
    static func h07() -> String {
        return ExPlayerEngine.ringBufferSummary()
    }

    /// M09：本地 SPM 包：泛型请求 + actor
    static func m09() -> String {
        let client = ExHTTPClient()
        let song = (try? client.request(ExSongEndpoint(id: 7)))?.name ?? "request-failed"
        return song
    }

    /// M09b：SPM 包里的 actor + async
    static func m09b() -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "timeout"
        Task.detached {
            result = await ExCache.shared.roundTrip()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    /// M10：Target-Action 中介者 → App 里的 Target_xxx
    static func m10() -> String {
        let player = ExMediator.shared().performTarget("Player", action: "info", params: ["k": "v"]) as? String ?? "nil"
        let settings = ExMediator.shared().performTarget("Settings", action: "info", params: nil) as? String ?? "nil"
        return player + " " + settings
    }
}
