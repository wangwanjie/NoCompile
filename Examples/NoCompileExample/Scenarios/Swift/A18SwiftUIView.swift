//
//  A18SwiftUIView.swift
//  场景 A18：SwiftUI。body 经 SwiftUI 运行时通过 witness table 调用
//

import SwiftUI

struct A18View: View {
    static func title() -> String {
        return "A18(@@v1@@)"
    }

    var body: some View {
        VStack {
            Text(A18View.title())
            Text(A18Style.subtitle())
        }
    }
}

enum A18Style {
    static func subtitle() -> String {
        return "sub"
    }
}

/// 直接取 body，转成字符串后找出令牌（静态派发路径）
enum A18 {
    static func probe() -> String {
        var dumped = ""
        dump(A18View().body, to: &dumped)
        let token = dumped.range(of: "A18\\(@@v\\d+@@\\)", options: .regularExpression).map { String(dumped[$0]) } ?? "no-token"
        return "A18 \(A18View.title()) body=\(token)"
    }
}
