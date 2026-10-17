//
//  S03AddStoredProperty.swift
//  场景 S03：给 Swift 类增加存储属性（实例布局变化）。要求：不崩溃；旧实例保持可用
//

import Foundation

final class S03Model {
    var name = "S03-name"
    // S03-DECL

    func describe() -> String {
        return name // S03-USE
    }
}

enum S03 {
    static let longLived = S03Model()

    static func probe() -> String {
        // 旧实例（启动时创建）+ 新建实例都要能用
        return "old[\(longLived.describe())] new[\(S03Model().describe())]"
    }
}
