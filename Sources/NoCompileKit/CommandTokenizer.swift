//
//  CommandTokenizer.swift
//  把 Xcode 日志里一行命令切成参数数组。
//
//  Xcode 的编译命令行对参数做了两种转义：空格等特殊字符用反斜杠转义（如 \=、\ ），
//  含空格的路径有时用双引号包裹。这里按这两种规则还原出原始参数，
//  之后全部用数组方式传给子进程，避免二次 shell 解析。
//

import Foundation

public enum CommandTokenizer {
    /// 把一行命令切分为 [可执行文件, 参数...]
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var index = line.startIndex
        var quote: Character? = nil

        while index < line.endIndex {
            let ch = line[index]
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\", let next = line.index(index, offsetBy: 1, limitedBy: line.endIndex), next < line.endIndex {
                    // 引号内的反斜杠转义
                    current.append(line[next])
                    index = next
                } else {
                    current.append(ch)
                }
                hasToken = true
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch == "\\" {
                if let next = line.index(index, offsetBy: 1, limitedBy: line.endIndex), next < line.endIndex {
                    current.append(line[next])
                    index = next
                    hasToken = true
                }
            } else if ch == " " || ch == "\t" {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(ch)
                hasToken = true
            }
            index = line.index(after: index)
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }
}
