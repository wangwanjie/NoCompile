//
//  ClientCompatibility.swift
//  判断已连接的客户端与当前 Mac 端是否匹配。
//
//  典型问题：用 bundle 方式接入时，nocompile_copy_bundle.sh 在 App 构建时把 Mac 端随附的 bundle 拷进 App 包；
//  之后 Mac 端升级了，App 却没有重新编译，包里仍是旧 bundle。新旧两端行为不一致，可能注入失败甚至卡住。
//  检测依据：
//  1. 客户端上报的版本号（旧客户端没有该字段）与 Mac 端不同；
//  2. 以 bundle 方式加载时，客户端镜像的 LC_UUID 不在 Mac 端随附 bundle 的 UUID 集合内（同版本号的开发构建也能识别）。
//

import Foundation

public enum ClientCompatibility {

    /// 返回不兼容原因；兼容返回 nil
    public static func issue(for info: [String: Any], bundledClientDirectory: String?) -> String? {
        if let protocolVersion = info["protocol"] as? Int, protocolVersion != NCProtocol.version {
            return "App 内的 NoCompile 客户端协议版本为 \(protocolVersion)，Mac 端为 \(NCProtocol.version)"
        }
        guard let version = info["clientVersion"] as? String, !version.isEmpty else {
            return "App 内的 NoCompile 客户端是旧版本（未上报版本号），与当前 Mac 端 \(NCProtocol.clientVersion) 不一致"
        }
        if version != NCProtocol.clientVersion {
            return "App 内的 NoCompile 客户端版本为 \(version)，与当前 Mac 端 \(NCProtocol.clientVersion) 不一致"
        }
        // bundle 方式加载：与 Mac 端随附的 bundle 逐个比对 UUID
        if let image = info["clientImage"] as? String, image.contains(".bundle/"),
           let uuid = (info["clientUUID"] as? String)?.uppercased(), !uuid.isEmpty,
           let directory = bundledClientDirectory {
            let shipped = shippedBundleUUIDs(in: directory)
            if !shipped.isEmpty, !shipped.contains(uuid) {
                let bundleName = image.components(separatedBy: "/").first { $0.hasSuffix(".bundle") } ?? "NoCompile.bundle"
                return "App 内的 \(bundleName) 与当前 Mac 端随附的客户端 bundle 不一致（App 打包时拷贝的是旧 bundle）"
            }
        }
        return nil
    }

    private static var cachedUUIDs: [String: Set<String>] = [:]
    private static let lock = NSLock()

    /// 目录下所有 *NoCompile.bundle 可执行文件的 UUID（含胖二进制的各架构）
    static func shippedBundleUUIDs(in directory: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedUUIDs[directory] {
            return cached
        }
        var result = Set<String>()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for entry in entries where entry.hasSuffix("NoCompile.bundle") {
            let path = (directory as NSString).appendingPathComponent(entry)
            if let executable = Bundle(path: path)?.executablePath {
                result.formUnion(MachOUUID.uuids(ofFileAt: executable))
            }
        }
        cachedUUIDs[directory] = result
        Diagnostics.shared.log("兼容性", "随附客户端 bundle 目录 \(directory)：\(result.count) 个 UUID", level: .debug)
        return result
    }
}

/// 读取 Mach-O（含胖二进制）中的 LC_UUID
enum MachOUUID {

    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let magic64: UInt32 = 0xFEEDFACF
    private static let magic32: UInt32 = 0xFEEDFACE
    private static let lcUUID: UInt32 = 0x1B

    static func uuids(ofFileAt path: String) -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), data.count >= 8 else {
            return []
        }
        let magic = readUInt32(data, 0, bigEndian: true)
        if magic == fatMagic || magic == fatMagic64 {
            // 胖二进制头为大端：nfat_arch 之后依次是 fat_arch（20 字节）或 fat_arch_64（32 字节）
            let count = Int(readUInt32(data, 4, bigEndian: true))
            let entrySize = magic == fatMagic ? 20 : 32
            var result = Set<String>()
            for i in 0 ..< min(count, 16) {
                let entry = 8 + i * entrySize
                guard entry + entrySize <= data.count else {
                    break
                }
                let offset = magic == fatMagic
                    ? Int(readUInt32(data, entry + 8, bigEndian: true))
                    : Int(readUInt64(data, entry + 8, bigEndian: true))
                if let uuid = uuid(inThinAt: offset, data: data) {
                    result.insert(uuid)
                }
            }
            return result
        }
        return uuid(inThinAt: 0, data: data).map { [$0] } ?? []
    }

    private static func uuid(inThinAt offset: Int, data: Data) -> String? {
        guard offset + 32 <= data.count else {
            return nil
        }
        let magic = readUInt32(data, offset, bigEndian: false)
        guard magic == magic64 || magic == magic32 else {
            return nil
        }
        let headerSize = magic == magic64 ? 32 : 28
        let commandCount = Int(readUInt32(data, offset + 16, bigEndian: false))
        var cursor = offset + headerSize
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= data.count else {
                return nil
            }
            let command = readUInt32(data, cursor, bigEndian: false)
            let size = Int(readUInt32(data, cursor + 4, bigEndian: false))
            if command == lcUUID, cursor + 24 <= data.count {
                let bytes = [UInt8](data[(data.startIndex + cursor + 8) ..< (data.startIndex + cursor + 24)])
                let uuid = bytes.withUnsafeBufferPointer { buffer -> uuid_t in
                    var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: buffer) }
                    return value
                }
                return UUID(uuid: uuid).uuidString
            }
            guard size > 0 else {
                return nil
            }
            cursor += size
        }
        return nil
    }

    private static func readUInt32(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { raw in
            raw.copyBytes(from: data[(data.startIndex + offset) ..< (data.startIndex + offset + 4)])
        }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    private static func readUInt64(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { raw in
            raw.copyBytes(from: data[(data.startIndex + offset) ..< (data.startIndex + offset + 8)])
        }
        return bigEndian ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
    }
}
