//
//  ExampleItems.swift
//  汇总各语言的验证项，iOS 与 macOS 界面共用
//

import Foundation

struct ExampleItem {
    let language: String
    let file: String
    let text: String
}

enum ExampleItems {
    static func all() -> [ExampleItem] {
        return [
            ExampleItem(language: "Swift", file: "SwiftGreeter.swift", text: SwiftGreeter.message()),
            ExampleItem(language: "Objective-C", file: "ObjCGreeter.m", text: ObjCGreeter.message()),
            ExampleItem(language: "C", file: "CGreeting.c", text: String(cString: c_greeting())),
            ExampleItem(language: "C++", file: "CppCounter.cpp", text: CppBridge.message()),
        ]
    }

    /// 界面构建时间：每次热重载刷新后都会变化，便于确认界面确实重建了
    static func buildStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "界面构建于 \(formatter.string(from: Date()))"
    }
}
