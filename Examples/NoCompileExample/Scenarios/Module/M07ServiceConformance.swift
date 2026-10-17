//
//  M07ServiceConformance.swift
//  场景 M07：App 里的类型遵循 framework 的协议；run() 用 framework 里的默认实现
//  场景 M07b：App 自己实现 run()
//

import Foundation
import ExKit

struct M07DefaultService: ExService {
    let name = "default"
}

struct M07CustomService: ExService {
    let name = "custom"

    func run() -> String {
        return "M07b(@@v1@@)"
    }
}

enum M07 {
    static func probe() -> String {
        let services: [ExService] = [M07DefaultService(), M07CustomService()]
        return services.map { $0.describe() }.joined(separator: " ")
    }
}
