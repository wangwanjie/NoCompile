//
//  A02SwiftStruct.swift
//  场景 A02：Swift 值类型（struct）的静态 / 实例 / mutating 方法与计算属性
//

import Foundation

struct A02Point {
    var x: Int
    var y: Int

    static func origin() -> A02Point {
        return A02Point(x: 0, y: 0)
    }

    var magnitude: Int {
        return abs(x) + abs(y)
    }

    mutating func move(dx: Int, dy: Int) {
        x += dx
        y += dy
    }

    func describe() -> String {
        return "A02(@@v1@@) \(x),\(y) m=\(magnitude)"
    }
}

enum A02 {
    static func probe() -> String {
        var point = A02Point.origin()
        point.move(dx: 3, dy: -4)
        return point.describe()
    }
}
