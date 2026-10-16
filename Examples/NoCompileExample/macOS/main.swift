//
//  main.swift
//  NoCompile macOS 示例入口
//
//  注意：业务代码中没有任何 NoCompile 相关的调用或 import。
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
