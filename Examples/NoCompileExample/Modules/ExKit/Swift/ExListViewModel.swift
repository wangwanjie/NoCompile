//
//  ExListViewModel.swift
//  场景 M04：framework 内的泛型 open class，由 App 里的子类重写方法
//

import Foundation

open class ExListViewModel<Item> {
    public private(set) var items: [Item] = []

    public init() {}

    public func append(_ item: Item) {
        items.append(item)
    }

    /// 子类可以重写
    open func title(for item: Item) -> String {
        return "ExListViewModel(@@v1@@)"
    }

    open func summary() -> String {
        return items.map { title(for: $0) }.joined(separator: ",")
    }
}
