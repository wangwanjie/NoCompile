//
//  ExCache.swift
//  actor + async/await：场景 A13 / M09
//

import Foundation

public actor ExCache {
    private var storage: [String: String] = [:]
    public static let shared = ExCache()

    public init() {}

    public func store(_ value: String, for key: String) {
        storage[key] = value
    }

    public func value(for key: String) -> String {
        return storage[key] ?? "miss"
    }

    /// 异步方法：把令牌写入缓存再读出
    public func roundTrip() async -> String {
        store("cache-@@v1@@", for: "k")
        return value(for: "k")
    }
}
