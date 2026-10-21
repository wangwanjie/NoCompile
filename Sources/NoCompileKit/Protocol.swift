//
//  Protocol.swift
//  与客户端的通信协议（须与 Sources/NoCompileClient/NCProtocol.h 保持一致）
//

import Foundation

/// 协议常量
public enum NCProtocol {
    public static let magic: UInt32 = 0x504D434E   // "NCMP"
    public static let version: Int = 1
    /// 客户端版本：须与 Sources/NoCompileClient/NCProtocol.h 的 NC_CLIENT_VERSION、
    /// App/project.yml 的 MARKETING_VERSION 同步更新。仅用于展示与诊断，不参与兼容性判断
    public static let clientVersion: String = "0.2.8"
    /// 客户端修订号：须与 NCProtocol.h 的 NC_CLIENT_REVISION 一致。握手时比对，不一致则不推送热重载并提示重新编译 App。
    /// 只有客户端（Sources/NoCompileClient）的行为或与 Mac 端的交互发生不兼容变化时才递增；发版改版本号不需要动它
    public static let clientRevision: Int = 1
    public static let macPort: UInt16 = 21890
    public static let devicePort: UInt16 = 21891
    public static let maxJSONLength: UInt32 = 16 * 1024 * 1024
    public static let maxDataLength: UInt64 = 1024 * 1024 * 1024
}

/// 消息类型
public enum NCMessageType: UInt32 {
    case hello = 1
    case helloAck = 2
    case log = 3
    case status = 4
    case config = 5
    case inject = 10
    case injectResult = 11
    case resource = 12
    case resourceResult = 13
    case ping = 20
    case pong = 21
}

/// 一帧消息
public struct NCMessage {
    public let type: NCMessageType
    public let json: [String: Any]?
    public let data: Data?

    public init(type: NCMessageType, json: [String: Any]? = nil, data: Data? = nil) {
        self.type = type
        self.json = json
        self.data = data
    }
}

/// 帧编解码。帧头固定 20 字节（小端）：magic(4) type(4) jsonLen(4) dataLen(8)
public enum NCFrameCodec {
    static let headerSize = 20

    public static func encode(_ message: NCMessage) -> Data {
        var jsonData = Data()
        if let json = message.json {
            jsonData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
        let payload = message.data ?? Data()

        var frame = Data()
        frame.appendLE(NCProtocol.magic)
        frame.appendLE(message.type.rawValue)
        frame.appendLE(UInt32(jsonData.count))
        frame.appendLE(UInt64(payload.count))
        frame.append(jsonData)
        frame.append(payload)
        return frame
    }

    /// 从缓冲区尝试解出一帧；成功返回消息与消耗的字节数，数据不足返回 nil
    public static func decode(from buffer: Data) throws -> (message: NCMessage, consumed: Int)? {
        guard buffer.count >= headerSize else {
            return nil
        }
        var offset = buffer.startIndex
        let magic: UInt32 = buffer.readLE(at: &offset)
        guard magic == NCProtocol.magic else {
            throw NCError.protocolMismatch
        }
        let rawType: UInt32 = buffer.readLE(at: &offset)
        let jsonLen: UInt32 = buffer.readLE(at: &offset)
        let dataLen: UInt64 = buffer.readLE(at: &offset)
        guard jsonLen <= NCProtocol.maxJSONLength, dataLen <= NCProtocol.maxDataLength else {
            throw NCError.frameTooLarge
        }
        let totalNeeded = headerSize + Int(jsonLen) + Int(dataLen)
        guard buffer.count >= totalNeeded else {
            return nil
        }
        var json: [String: Any]? = nil
        if jsonLen > 0 {
            let jsonData = buffer.subdata(in: offset ..< offset + Int(jsonLen))
            json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            offset += Int(jsonLen)
        }
        var data: Data? = nil
        if dataLen > 0 {
            data = buffer.subdata(in: offset ..< offset + Int(dataLen))
        }
        guard let messageType = NCMessageType(rawValue: rawType) else {
            // 未知类型也要消费掉，避免卡死
            return (NCMessage(type: .log, json: nil, data: nil), totalNeeded)
        }
        return (NCMessage(type: messageType, json: json, data: data), totalNeeded)
    }
}

public enum NCError: Error {
    case protocolMismatch
    case frameTooLarge
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: inout Index) -> T {
        let size = MemoryLayout<T>.size
        let slice = subdata(in: offset ..< offset + size)
        offset += size
        return slice.withUnsafeBytes { $0.loadUnaligned(as: T.self).littleEndian }
    }
}
