//
//  Synchronized.swift
//  加锁访问的属性包装器。
//
//  引擎的偏好属性（保存即注入、排除关键字、下发给 App 的配置等）由主线程写入、在引擎队列上读取，
//  Array / Dictionary 等值类型并发读写会破坏内存。用该包装器让每次读写都在锁内完成。
//

import Foundation

@propertyWrapper
public struct Synchronized<Value> {

    /// 引用类型的存储：包装器本身被拷贝时仍共享同一份值与锁
    private final class Storage {
        let lock = NSLock()
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let storage: Storage

    public init(wrappedValue: Value) {
        storage = Storage(wrappedValue)
    }

    public var wrappedValue: Value {
        get {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.value
        }
        // nonmutating：写入只改动共享存储，不改写包装器本身，读线程不会读到写了一半的包装器
        nonmutating set {
            storage.lock.lock()
            storage.value = newValue
            storage.lock.unlock()
        }
    }
}
