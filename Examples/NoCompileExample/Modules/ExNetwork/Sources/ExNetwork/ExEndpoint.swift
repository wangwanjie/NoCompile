//
//  ExEndpoint.swift
//  场景 M09：SPM 包里的泛型协议 + 关联类型
//

import Foundation

public protocol ExEndpoint {
    associatedtype Response: Decodable
    var path: String { get }
}

public struct ExSongEndpoint: ExEndpoint {
    public typealias Response = ExSong
    public let id: Int

    public init(id: Int) {
        self.id = id
    }

    public var path: String {
        return "/song/\(id)"
    }
}

public struct ExSong: Decodable, Equatable {
    public let id: Int
    public let name: String
}
