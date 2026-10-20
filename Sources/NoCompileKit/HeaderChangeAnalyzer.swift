//
//  HeaderChangeAnalyzer.swift
//  头文件变更分析：同步 framework 头文件副本，并只挑出真正用到改动内容的依赖文件。
//

import Foundation

public final class HeaderChangeAnalyzer {

    /// 头文件上一次已知的内容。用来对比出这次改了哪些标识符
    private var snapshots: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - 快照

    /// 记录一批头文件的当前内容（引擎启动后在后台为"被大量文件引用的头文件"建立基线）。
    /// 修改时间晚于 cutoff 的跳过：那是用户在基线建立期间刚保存的新内容，拿它当旧内容会比不出差异
    public func prime(headers: [String], modifiedBefore cutoff: Date = Date()) {
        for header in headers {
            let modified = (try? FileManager.default.attributesOfItem(atPath: header))?[.modificationDate] as? Date
            if let modified, modified > cutoff {
                continue
            }
            guard let text = try? String(contentsOfFile: header, encoding: .utf8) else {
                continue
            }
            lock.lock()
            if snapshots[header] == nil {
                snapshots[header] = text
            }
            lock.unlock()
        }
    }

    private func snapshot(for header: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[header]
    }

    func update(_ header: String, text: String) {
        lock.lock()
        snapshots[header] = text
        lock.unlock()
    }

    // MARK: - framework 头文件副本

    /// 把源头文件的新内容同步到构建产物里的副本。返回 (副本路径, 副本的旧内容)。
    /// 判断是否为同一份头文件的副本：同名，且旧内容与新内容大部分行相同（防止把重名的另一个头文件覆盖掉）
    func syncProductCopies(of header: String, newText: String, index: HeaderDependencyIndex,
                           knownCopy: String?) -> [(path: String, oldText: String)] {
        let name = (header as NSString).lastPathComponent
        var synced: [(String, String)] = []
        // 构建日志里记录过的拷贝目标最可靠；没有记录时按"同名且内容相近"在产物目录里找
        let candidates = knownCopy.map { [ParsedCommands.canonicalPath($0)] } ?? index.productCopies(ofHeaderNamed: name)
        for copy in candidates where copy != header {
            guard let oldText = try? String(contentsOfFile: copy, encoding: .utf8) else {
                continue
            }
            guard knownCopy != nil || Self.similarity(oldText, newText) >= 0.6 else {
                continue
            }
            if oldText != newText {
                do {
                    try newText.write(toFile: copy, atomically: true, encoding: .utf8)
                } catch {
                    Diagnostics.shared.log("头文件", "同步副本失败：\(copy)：\(error.localizedDescription)", level: .warning)
                    continue
                }
                Diagnostics.shared.log("头文件", "已同步构建产物里的副本：\(copy)", level: .debug)
            }
            synced.append((copy, oldText))
        }
        return synced
    }

    /// 两段文本共有的行占较大者的比例
    static func similarity(_ a: String, _ b: String) -> Double {
        let linesA = Set(a.components(separatedBy: "\n"))
        let linesB = Set(b.components(separatedBy: "\n"))
        let larger = max(linesA.count, linesB.count)
        guard larger > 0 else {
            return 1
        }
        return Double(linesA.intersection(linesB).count) / Double(larger)
    }

    // MARK: - 改动的标识符

    /// 这次改动涉及的标识符：新旧内容差异行里出现的名字。拿不到旧内容时返回 nil
    func changedIdentifiers(header: String, newText: String, extraOldTexts: [String]) -> Set<String>? {
        var oldText = snapshot(for: header)
        if oldText == nil {
            oldText = extraOldTexts.first
        }
        if oldText == nil {
            oldText = Self.gitHeadContent(of: header)
        }
        update(header, text: newText)
        // 新旧内容相同（基线读到的已经是保存后的内容）：比不出改了什么，按拿不到旧内容处理，由调用方退而用全部声明的标识符
        guard let oldText, oldText != newText else {
            return nil
        }
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        var counts: [String: Int] = [:]
        for line in oldLines {
            counts[line, default: 0] += 1
        }
        var changed: [String] = []
        var changedIndexes: [Int] = []
        for (index, line) in newLines.enumerated() {
            if let n = counts[line], n > 0 {
                counts[line] = n - 1
            } else {
                changed.append(line)
                changedIndexes.append(index)
            }
        }
        for (line, n) in counts where n > 0 {
            changed.append(line)
        }
        var result = Self.identifiers(in: changed.joined(separator: "\n"))
        // 改动落在函数体 / 枚举体 / 结构体里时，外层声明本身（函数名、类型名）也算被改动：
        // 使用方引用的是函数名，而不是函数体里改了的那一行
        for index in changedIndexes {
            for opener in Self.enclosingOpenerLines(of: index, in: newLines) {
                result.formUnion(Self.identifiers(in: newLines[opener]))
            }
        }
        return result
    }

    /// 第 index 行外层花括号的起始行（由内向外），用简单的括号计数估算
    static func enclosingOpenerLines(of index: Int, in lines: [String]) -> [Int] {
        guard index < lines.count else {
            return []
        }
        var openers: [Int] = []
        var needed = 1  // 还需要向上越过多少个未闭合的 "{"
        var line = index
        if Self.braceBalance(of: lines[index]) > 0 {
            // 本行自己打开了新块（如 "foo() {"），它本身就是外层声明
            return [index]
        }
        while line > 0 {
            line -= 1
            let balance = Self.braceBalance(of: lines[line])
            // balance > 0：这一行净打开了块；< 0：净关闭了块
            if balance > 0 {
                let consumed = min(balance, needed)
                needed -= consumed
                if consumed > 0 {
                    openers.append(line)
                }
                if needed <= 0 {
                    // 找到一个外层块，继续向外找更外层的
                    needed = 1
                }
            } else if balance < 0 {
                needed += -balance
            }
            if openers.count >= 4 {
                break
            }
        }
        return openers
    }

    /// 一行里 "{" 与 "}" 的净数量（忽略字符串与行尾注释的简化处理）
    static func braceBalance(of line: String) -> Int {
        var balance = 0
        var inString = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if ch == "/" && previous == "/" {
                    break
                }
                if ch == "{" {
                    balance += 1
                } else if ch == "}" {
                    balance -= 1
                }
            }
            previous = ch
        }
        return balance
    }

    /// 头文件里"声明 / 定义"的标识符：宏、函数、枚举（及枚举项）、结构体、类、协议、extern 常量。
    /// 拿不到旧内容、无法对比差异时，用它近似"这个头文件可能改了什么"
    static func declaredIdentifiers(in text: String) -> Set<String> {
        let patterns = [
            #"#\s*define\s+([A-Za-z_][A-Za-z0-9_]{2,})"#,
            #"\b([A-Za-z_][A-Za-z0-9_]{2,})\s*\("#,
            #"NS_(?:ENUM|OPTIONS|CLOSED_ENUM|ERROR_ENUM)\s*\(\s*[A-Za-z_][A-Za-z0-9_ ]*,\s*([A-Za-z_][A-Za-z0-9_]+)"#,
            #"\b(?:enum|struct|union|class)\s+([A-Za-z_][A-Za-z0-9_]{2,})"#,
            #"@(?:interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]{2,})"#,
            #"\}\s*([A-Za-z_][A-Za-z0-9_]{2,})\s*;"#,
            #"(?m)^\s*([A-Za-z_][A-Za-z0-9_]{2,})\s*(?:=[^,;]+)?,\s*(?://.*)?$"#,
            #"(?:extern|FOUNDATION_EXPORT|UIKIT_EXTERN)\b[^;(]*?\b([A-Za-z_][A-Za-z0-9_]{2,})\s*(?:\[[^\]]*\])?\s*;"#,
        ]
        var result = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                if let r = Range(match.range(at: 1), in: text) {
                    result.insert(String(text[r]))
                }
            }
        }
        let keywords: Set<String> = ["if", "while", "for", "switch", "return", "sizeof", "defined", "typeof", "__attribute__",
                                     "NS_ENUM", "NS_OPTIONS", "NS_SWIFT_NAME", "NS_AVAILABLE", "API_AVAILABLE", "NS_DESIGNATED_INITIALIZER",
                                     "NS_UNAVAILABLE", "NS_REFINED_FOR_SWIFT", "__has_include", "__has_feature"]
        return result.subtracting(commonWords).subtracting(keywords)
    }

    static let identifierRegex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]{2,}"#)

    static func identifiers(in text: String) -> Set<String> {
        guard let regex = identifierRegex else {
            return []
        }
        var result = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                result.insert(String(text[r]))
            }
        }
        // 去掉各种头文件里到处都是的语法关键字，避免所有文件都被判定为受影响
        return result.subtracting(Self.commonWords)
    }

    private static let commonWords: Set<String> = [
        "NS_ASSUME_NONNULL_BEGIN", "NS_ASSUME_NONNULL_END", "interface", "implementation", "property", "nonatomic", "strong",
        "weak", "copy", "assign", "readonly", "readwrite", "atomic", "retain", "const", "static", "inline", "extern",
        "typedef", "struct", "enum", "void", "return", "include", "import", "define", "ifndef", "endif", "ifdef", "else",
        "nullable", "nonnull", "Foundation", "UIKit", "end", "class", "protocol", "int", "char", "long", "unsigned",
    ]

    /// 文件在 git HEAD 里的内容（文件已被 git 跟踪时）
    static func gitHeadContent(of path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let result = Shell.run("/usr/bin/git", ["-C", directory, "show", "HEAD:./\(name)"], timeout: 10)
        return result.succeeded ? result.stdout : nil
    }

    // MARK: - 筛选依赖文件

    /// 从依赖文件里挑出文本中提到任一改动标识符的
    static func filter(sources: [String], mentioning identifiers: Set<String>) -> [String] {
        guard !identifiers.isEmpty else {
            return []
        }
        let escaped = identifiers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b") else {
            return sources
        }
        return sources.filter { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return true
            }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
