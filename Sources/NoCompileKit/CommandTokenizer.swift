//
//  CommandTokenizer.swift
//  把 Xcode 日志里一行命令切成参数数组。
//
//  Xcode 的编译命令行对参数做了两种转义：空格等特殊字符用反斜杠转义（如 \=、\ ），
//  含空格的路径有时用双引号包裹；swiftc -### 的输出则用单引号包裹。这里按 shell 的规则还原出原始参数
//  （单引号内全部按字面处理，双引号内反斜杠只转义 " \ $ `），
//  之后全部用数组方式传给子进程，避免二次 shell 解析。
//
//  按 UTF-8 字节切分：大型工程的构建日志里有上万条长命令，逐 Character 遍历非常慢。
//  引号、反斜杠、空格都是 ASCII，不会出现在多字节字符内部，按字节处理与按字符处理结果一致。
//

import Foundation

public enum CommandTokenizer {

    private static let backslash = UInt8(ascii: "\\")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let singleQuote = UInt8(ascii: "'")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    /// 双引号内可被反斜杠转义的字符
    private static let escapableInDoubleQuotes: Set<UInt8> = [
        UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "$"), UInt8(ascii: "`"),
    ]

    /// 把一行命令切分为 [可执行文件, 参数...]
    public static func tokenize(_ line: String) -> [String] {
        var line = line
        return line.withUTF8 { tokenize(bytes: $0) }
    }

    /// 字节版本，供构建日志解析直接使用，省去一次 String 转换
    public static func tokenize(bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var tokens: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(256)
        var hasToken = false
        var quote: UInt8? = nil
        var index = 0
        let count = bytes.count

        while index < count {
            let byte = bytes[index]
            if let q = quote {
                if byte == q {
                    quote = nil
                } else if q == doubleQuote, byte == backslash, index + 1 < count,
                          Self.escapableInDoubleQuotes.contains(bytes[index + 1]) {
                    // 与 shell 一致：双引号内的反斜杠只转义 " \ $ ` 这几个字符，其余情况原样保留
                    index += 1
                    current.append(bytes[index])
                } else {
                    // 单引号内全部按字面处理（swiftc -### 输出的 '-DM=a\b' 中的反斜杠要保留）
                    current.append(byte)
                }
                hasToken = true
            } else if byte == doubleQuote || byte == singleQuote {
                quote = byte
                hasToken = true
            } else if byte == backslash {
                if index + 1 < count {
                    index += 1
                    current.append(bytes[index])
                    hasToken = true
                }
            } else if byte == space || byte == tab {
                if hasToken {
                    tokens.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                    hasToken = false
                }
            } else {
                current.append(byte)
                hasToken = true
            }
            index += 1
        }
        if hasToken {
            tokens.append(String(decoding: current, as: UTF8.self))
        }
        return tokens
    }
}
