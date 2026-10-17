//
//  A11SwiftPropertyWrapper.swift
//  场景 A11：本地定义的 property wrapper
//

import Foundation

@propertyWrapper
struct A11Trimmed {
    private var value: String = ""

    var wrappedValue: String {
        get {
            return value
        }
        set {
            // 取前 5 个字符 @@v1@@
            value = String(newValue.prefix(5))
        }
    }

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }
}

struct A11Profile {
    @A11Trimmed var name: String = ""
}

enum A11 {
    static func probe() -> String {
        var profile = A11Profile()
        profile.name = "abcdefghij"
        return "A11:\(profile.name)|"
    }
}
