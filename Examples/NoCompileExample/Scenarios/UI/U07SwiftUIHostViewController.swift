//
//  U07SwiftUIHostViewController.swift
//  场景 U07：UIHostingController 承载的 SwiftUI 页面（人工验证页面刷新用）
//

import SwiftUI
import UIKit

struct U07ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("U07 SwiftUI 页面")
                .font(.title2)
            Text("点击次数 \(taps)")
            Button("点我") {
                taps += 1
            }
        }
    }
}

enum U07 {
    static func makeController() -> UIViewController {
        return UIHostingController(rootView: U07ContentView())
    }
}
