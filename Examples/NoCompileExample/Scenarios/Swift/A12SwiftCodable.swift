//
//  A12SwiftCodable.swift
//  场景 A12：Codable 模型 + 自定义解码 + JSON 解析
//

import Foundation

struct A12Song: Codable {
    let id: Int
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case title = "song_name"
    }

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        // 自定义解码：拼上版本令牌 @@v1@@
        title = try container.decode(String.self, forKey: .title) + "-@@v1@@"
    }
}

enum A12 {
    static func probe() -> String {
        let json = "{\"id\": 5, \"song_name\": \"demo\"}"
        guard let song = try? JSONDecoder().decode(A12Song.self, from: Data(json.utf8)) else {
            return "A12 decode-failed"
        }
        let encoded = (try? JSONEncoder().encode(song)).flatMap { String(data: $0, encoding: .utf8) } ?? "enc-failed"
        return "A12:\(song.id):\(song.title) \(encoded.count)"
    }
}
