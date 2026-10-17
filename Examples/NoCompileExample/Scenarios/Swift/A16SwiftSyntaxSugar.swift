//
//  A16SwiftSyntaxSugar.swift
//  场景 A16：result builder、自定义运算符、自定义字符串插值、some 不透明类型
//

import Foundation

@resultBuilder
enum A16TextBuilder {
    static func buildBlock(_ parts: String...) -> String {
        return parts.joined(separator: "+")
    }
}

func a16Build(@A16TextBuilder _ content: () -> String) -> String {
    return content()
}

infix operator <+>: AdditionPrecedence

func <+> (lhs: String, rhs: String) -> String {
    return lhs + "<+>" + rhs + "@@v1@@"
}

struct A16Message: ExpressibleByStringInterpolation, CustomStringConvertible {
    let description: String

    init(stringLiteral value: String) {
        description = value
    }

    init(stringInterpolation: DefaultStringInterpolation) {
        description = stringInterpolation.description
    }
}

func a16Opaque() -> some Sequence {
    return [1, 2, 3]
}

enum A16 {
    static func probe() -> String {
        let built = a16Build {
            "a"
            "b"
        }
        let message: A16Message = "m=\(1 + 1)"
        let count = Array(a16Opaque()).count
        return "A16 \(built) \("l" <+> "r") \(message) \(count)"
    }
}
