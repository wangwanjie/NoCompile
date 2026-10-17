//
//  S06AddEnumCase.swift
//  场景 S06：给 Swift 枚举增加 case（有负载的枚举布局会变）
//

import Foundation

enum S06Event {
    case start
    case stop(reason: String)
    // S06-DECL

    func describe() -> String {
        switch self {
        case .start:
            return "start"
        case .stop(let reason):
            return "stop:\(reason)"
        // S06-CASE
        }
    }
}

enum S06 {
    static func probe() -> String {
        let events: [S06Event] = [.start, .stop(reason: "r")]
        return events.map { $0.describe() }.joined(separator: ",") // S06-USE
    }
}
