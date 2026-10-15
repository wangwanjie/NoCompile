//
//  main.swift
//  DemoMac：每秒打印 Greeter.message() 与 globalBanner()，
//  用于观察热重载注入后输出是否实时变化。
//

import Foundation
#if DEBUG
import NoCompileClient
#endif

let greeter = Greeter()
var tick = 0

let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    tick += 1
    print("[\(tick)] \(greeter.message())  \(globalBanner())")
    fflush(stdout)
}
RunLoop.main.add(timer, forMode: .common)

print("DemoMac 启动，等待热重载…（客户端会自动连接 127.0.0.1:21890）")
fflush(stdout)
RunLoop.main.run()
