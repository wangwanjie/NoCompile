//
//  ProtocolTests.swift
//  帧编解码：帧头布局、分段到达、超长与非法帧
//

import XCTest
@testable import NoCompileKit

final class ProtocolTests: XCTestCase {

    func testHeaderLayoutIsLittleEndian() {
        let frame = NCFrameCodec.encode(NCMessage(type: .ping))
        XCTAssertEqual(frame.count, 20)
        // magic "NCMP" 小端：4E 43 4D 50
        XCTAssertEqual(Array(frame.prefix(4)), [0x4E, 0x43, 0x4D, 0x50])
        XCTAssertEqual(Array(frame[4 ..< 8]), [20, 0, 0, 0])
        XCTAssertEqual(Array(frame[8 ..< 20]), Array(repeating: 0, count: 12))
    }

    func testRoundTripWithJSONAndData() throws {
        let payload = Data((0 ..< 300).map { UInt8($0 % 256) })
        let message = NCMessage(type: .inject, json: ["file": "/a/中文.swift", "n": 3], data: payload)
        let frame = NCFrameCodec.encode(message)
        let decoded = try XCTUnwrap(NCFrameCodec.decode(from: frame))
        XCTAssertEqual(decoded.consumed, frame.count)
        XCTAssertEqual(decoded.message.type, .inject)
        XCTAssertEqual(decoded.message.json?["file"] as? String, "/a/中文.swift")
        XCTAssertEqual(decoded.message.json?["n"] as? Int, 3)
        XCTAssertEqual(decoded.message.data, payload)
    }

    func testIncompleteFrameReturnsNil() throws {
        let frame = NCFrameCodec.encode(NCMessage(type: .log, json: ["text": "hello"]))
        for length in [0, 5, 19, 20, frame.count - 1] {
            XCTAssertNil(try NCFrameCodec.decode(from: frame.prefix(length)), "长度 \(length) 不应解出帧")
        }
    }

    func testDecodesFromSlicedBufferAndLeavesRemainder() throws {
        let first = NCFrameCodec.encode(NCMessage(type: .ping))
        let second = NCFrameCodec.encode(NCMessage(type: .pong, json: ["k": "v"]))
        var buffer = Data([0xFF]) + first + second
        // 模拟连接层消费过数据后的切片（startIndex 不为 0）
        buffer = buffer.dropFirst()
        let one = try XCTUnwrap(NCFrameCodec.decode(from: buffer))
        XCTAssertEqual(one.message.type, .ping)
        buffer = buffer.dropFirst(one.consumed)
        let two = try XCTUnwrap(NCFrameCodec.decode(from: buffer))
        XCTAssertEqual(two.message.type, .pong)
        XCTAssertEqual(two.message.json?["k"] as? String, "v")
        XCTAssertEqual(two.consumed, buffer.count)
    }

    func testBadMagicThrows() {
        var frame = NCFrameCodec.encode(NCMessage(type: .ping))
        frame[0] = 0
        XCTAssertThrowsError(try NCFrameCodec.decode(from: frame))
    }

    func testOversizedLengthThrows() {
        var frame = NCFrameCodec.encode(NCMessage(type: .ping))
        // jsonLen 超过上限
        frame.replaceSubrange(8 ..< 12, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try NCFrameCodec.decode(from: frame))
    }

    func testUnknownTypeIsConsumed() throws {
        var frame = NCFrameCodec.encode(NCMessage(type: .ping, json: ["a": 1]))
        frame.replaceSubrange(4 ..< 8, with: [0xE7, 0x03, 0, 0])
        let decoded = try XCTUnwrap(NCFrameCodec.decode(from: frame))
        XCTAssertEqual(decoded.consumed, frame.count)
    }

    func testClientCompatibility() {
        XCTAssertNil(ClientCompatibility.issue(for: ["protocol": NCProtocol.version, "clientVersion": "x",
                                                     "clientRevision": NCProtocol.clientRevision]))
        XCTAssertNotNil(ClientCompatibility.issue(for: ["protocol": NCProtocol.version + 1]))
        XCTAssertNotNil(ClientCompatibility.issue(for: ["clientRevision": NCProtocol.clientRevision + 1]))
        // 引入修订号前的旧客户端：只有 0.2.4 视为兼容
        XCTAssertNil(ClientCompatibility.issue(for: ["clientVersion": "0.2.4"]))
        XCTAssertNotNil(ClientCompatibility.issue(for: ["clientVersion": "0.2.3"]))
        XCTAssertNotNil(ClientCompatibility.issue(for: [:]))
    }
}
