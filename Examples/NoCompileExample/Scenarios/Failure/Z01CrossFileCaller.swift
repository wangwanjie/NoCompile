//
//  Z01CrossFileCaller.swift
//

import Foundation

enum Z01 {
    static func probe() -> String {
        return "caller:" + z01Lib()
    }
}
