//
//  A08SwiftEnum.swift
//  场景 A08：带关联值 / RawRepresentable / CaseIterable 的枚举及其方法
//

import Foundation

enum A08Command {
    case play(track: String)
    case seek(seconds: Int)
    case stop

    func describe() -> String {
        switch self {
        case .play(let track):
            return "play \(track) @@v1@@"
        case .seek(let seconds):
            return "seek \(seconds)"
        case .stop:
            return "stop"
        }
    }
}

enum A08Level: Int, CaseIterable {
    case low = 1
    case mid
    case high

    var title: String {
        return "L\(rawValue)"
    }
}

enum A08 {
    static func probe() -> String {
        let commands: [A08Command] = [.play(track: "t"), .seek(seconds: 3), .stop]
        let levels = A08Level.allCases.map { $0.title }.joined()
        return commands.map { $0.describe() }.joined(separator: ";") + " " + levels
    }
}
