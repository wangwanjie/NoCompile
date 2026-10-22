//
//  VersionConsistencyTests.swift
//  发版时多处版本号必须同步：Mac App、客户端工程、podspec、两端协议常量。
//  任何一处漏改，握手展示与诊断就会对不上，这里在测试阶段拦住
//

import XCTest
@testable import NoCompileKit

final class VersionConsistencyTests: XCTestCase {

    /// 仓库根目录（本文件位于 Tests/NoCompileKitTests/）
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ relativePath: String) throws -> String {
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 取正则第一个捕获组的全部匹配
    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testAllVersionsMatchClientVersion() throws {
        let expected = NCProtocol.clientVersion

        let appVersions = captures(#"MARKETING_VERSION:\s*"?([0-9.]+)"#, in: try read("App/project.yml"))
        XCTAssertFalse(appVersions.isEmpty)
        XCTAssertTrue(appVersions.allSatisfy { $0 == expected }, "App/project.yml：\(appVersions)")

        let clientYml = captures(#"MARKETING_VERSION:\s*"?([0-9.]+)"#, in: try read("Client/project.yml"))
        XCTAssertTrue(!clientYml.isEmpty && clientYml.allSatisfy { $0 == expected }, "Client/project.yml：\(clientYml)")

        let pbx = captures(#"MARKETING_VERSION = ([0-9.]+);"#, in: try read("Client/NoCompileClient.xcodeproj/project.pbxproj"))
        XCTAssertTrue(!pbx.isEmpty && pbx.allSatisfy { $0 == expected }, "Client 工程：\(pbx)")

        let podspec = captures(#"s\.version\s*=\s*['"]([0-9.]+)['"]"#, in: try read("NoCompile.podspec"))
        XCTAssertEqual(podspec, [expected], "NoCompile.podspec")

        let header = try read("Sources/NoCompileClient/NCProtocol.h")
        XCTAssertEqual(captures(#"NC_CLIENT_VERSION\s+@"([0-9.]+)""#, in: header), [expected], "NC_CLIENT_VERSION")
        XCTAssertEqual(captures(#"NC_CLIENT_REVISION\s+([0-9]+)"#, in: header), ["\(NCProtocol.clientRevision)"], "NC_CLIENT_REVISION")
        XCTAssertEqual(captures(#"NC_PROTOCOL_VERSION\s+([0-9]+)"#, in: header), ["\(NCProtocol.version)"], "NC_PROTOCOL_VERSION")
    }

    func testPortsAndMagicMatchClientHeader() throws {
        let header = try read("Sources/NoCompileClient/NCProtocol.h")
        XCTAssertTrue(header.contains("\(NCProtocol.macPort)"), "Mac 端口 \(NCProtocol.macPort)")
        XCTAssertTrue(header.contains("\(NCProtocol.devicePort)"), "设备端口 \(NCProtocol.devicePort)")
        XCTAssertTrue(header.uppercased().contains(String(format: "0X%08X", NCProtocol.magic)), "magic")
    }

    func testMessageTypesMatchClientHeader() throws {
        let header = try read("Sources/NoCompileClient/NCProtocol.h")
        let names: [NCMessageType: String] = [
            .hello: "Hello", .helloAck: "HelloAck", .log: "Log", .status: "Status", .config: "Config",
            .inject: "Inject", .injectResult: "InjectResult", .resource: "Resource", .resourceResult: "ResourceResult",
            .ping: "Ping", .pong: "Pong",
        ]
        for (type, name) in names {
            let values = captures("NCMessageType\(name)\\s*=\\s*([0-9]+)", in: header)
            XCTAssertEqual(values, ["\(type.rawValue)"], "NCMessageType\(name)")
        }
    }
}
