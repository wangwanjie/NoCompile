//
//  A15SwiftOverrideObjC.swift
//  场景 A15：Swift 子类继承 ObjC 类（混合继承链），重写方法并调用 super
//

import Foundation

final class A15Widget: ObjCBaseWidget {
    override func title() -> String {
        return "A15(@@v1@@)<" + super.title() + ">"
    }

    @objc override func renderBody() -> String {
        return "body:" + title()
    }
}

enum A15 {
    static func probe() -> String {
        return A15Widget().renderBody()
    }
}
