//
//  ExHTTPClient.swift
//  伪造的网络层：同步返回 JSON 字符串，用于验证泛型函数、Result、throws
//

import Foundation

public enum ExHTTPError: Error, Equatable {
    case notFound(String)
    case decode(String)
}

public protocol ExTransport {
    func send(path: String) -> Result<Data, ExHTTPError>
}

public struct ExMockTransport: ExTransport {
    public init() {}

    public func send(path: String) -> Result<Data, ExHTTPError> {
        if path.hasPrefix("/song/") {
            let id = path.dropFirst("/song/".count)
            // 场景 M09：改这里的令牌
            let json = "{\"id\": \(id), \"name\": \"song-@@v1@@\"}"
            return .success(Data(json.utf8))
        }
        return .failure(.notFound(path))
    }
}

public final class ExHTTPClient {
    private let transport: ExTransport

    public init(transport: ExTransport = ExMockTransport()) {
        self.transport = transport
    }

    /// 泛型函数，按 Endpoint 的关联类型解码
    public func request<E: ExEndpoint>(_ endpoint: E) throws -> E.Response {
        switch transport.send(path: endpoint.path) {
        case .success(let data):
            do {
                return try JSONDecoder().decode(E.Response.self, from: data)
            } catch {
                throw ExHTTPError.decode("\(error)")
            }
        case .failure(let error):
            throw error
        }
    }
}
