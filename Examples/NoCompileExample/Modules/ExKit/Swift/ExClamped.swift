//
//  ExClamped.swift
//  property wrapper（跨模块使用）
//

import Foundation

@propertyWrapper
public struct ExClamped {
    private var value: Int
    private let range: ClosedRange<Int>

    public init(wrappedValue: Int, _ range: ClosedRange<Int>) {
        self.range = range
        self.value = min(max(wrappedValue, range.lowerBound), range.upperBound)
    }

    public var wrappedValue: Int {
        get {
            return value
        }
        set {
            // 场景 M09：@@v1@@
            value = min(max(newValue, range.lowerBound), range.upperBound)
        }
    }
}
