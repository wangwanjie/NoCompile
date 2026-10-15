//
//  Greeter.swift
//  热重载验证目标：修改 message() 的返回值并保存，
//  运行中的进程应立即打印出新内容。
//

import Foundation

final class Greeter {
    // 修改这里的字符串来验证热重载
    func message() -> String {
        return "你好，这是第 1 版实现"
    }
}

// 全局函数：验证函数级符号重绑（interpose）
func globalBanner() -> String {
    return "[banner v1]"
}
