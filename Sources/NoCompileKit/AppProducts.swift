//
//  AppProducts.swift
//  读取 DerivedData 中构建出的 .app：bundleID、主程序 LC_UUID、链接时间。
//
//  用途：
//  1. 判断连上来的 App 是否由当前工程构建：bundleID 要出现在本工程的产物中；
//     同名工程的多份副本（如两个目录下的 kugou.xcworkspace）bundleID 相同，再用主程序 UUID 区分。
//  2. 推算 App 的构建时间：UUID 与产物一致时，产物的修改时间就是 App 的链接时间，
//     早于它的改动已经编进 App，切换设备补推时不必再推。
//

import Foundation

public struct AppProduct {
    public let bundleID: String
    public let appPath: String
    /// 主程序与 .debug.dylib 中所有架构切片的 LC_UUID（大写、带连字符）
    public let uuids: Set<String>
    /// 主程序 / .debug.dylib 中较新的修改时间，即最近一次链接时间
    public let linkDate: Date
    /// 各二进制（主程序、.debug.dylib）的路径 → 其切片的 LC_UUID，用于按 UUID 找到 App 镜像对应的文件
    public var binaries: [String: Set<String>] = [:]
}

public enum AppProducts {

    private static let lock = NSLock()
    /// 可执行文件路径 → (修改时间, UUID)，文件没变就不重复读取
    private static var uuidCache: [String: (date: Date, uuids: Set<String>)] = [:]

    /// 列出 DerivedData/Build/Products 下各配置目录中的 .app
    public static func products(derivedDataPath: String) -> [AppProduct] {
        let fileManager = FileManager.default
        let productsDir = (derivedDataPath as NSString).appendingPathComponent("Build/Products")
        var result: [AppProduct] = []
        for configuration in (try? fileManager.contentsOfDirectory(atPath: productsDir)) ?? [] {
            let configurationDir = (productsDir as NSString).appendingPathComponent(configuration)
            for item in (try? fileManager.contentsOfDirectory(atPath: configurationDir)) ?? [] where item.hasSuffix(".app") {
                if let product = product(atPath: (configurationDir as NSString).appendingPathComponent(item)) {
                    result.append(product)
                }
            }
        }
        return result
    }

    /// 读取单个 .app。iOS 的 Info.plist 与可执行文件在包根目录，macOS 在 Contents 下
    public static func product(atPath appPath: String) -> AppProduct? {
        let layouts = [(plist: appPath + "/Info.plist", binaries: appPath),
                       (plist: appPath + "/Contents/Info.plist", binaries: appPath + "/Contents/MacOS")]
        for layout in layouts {
            guard let plist = NSDictionary(contentsOfFile: layout.plist),
                  let bundleID = plist["CFBundleIdentifier"] as? String else {
                continue
            }
            let executable = plist["CFBundleExecutable"] as? String ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            var uuids = Set<String>()
            var binaries: [String: Set<String>] = [:]
            var linkDate = Date.distantPast
            // Xcode 16 起 Debug 构建把代码放在 <可执行文件>.debug.dylib，主程序只是一个很小的启动壳
            for binary in [layout.binaries + "/" + executable, layout.binaries + "/" + executable + ".debug.dylib"] {
                guard let date = modificationDate(of: binary) else {
                    continue
                }
                let binaryUUIDs = cachedUUIDs(ofFile: binary, modified: date)
                uuids.formUnion(binaryUUIDs)
                binaries[binary] = binaryUUIDs
                linkDate = max(linkDate, date)
            }
            return AppProduct(bundleID: bundleID, appPath: appPath, uuids: uuids, linkDate: linkDate, binaries: binaries)
        }
        return nil
    }

    /// 在同一 DerivedData 根目录下的其他工程里找名为 appName 且 UUID 与给定集合相交的产物，
    /// 返回那个工程的路径（取 info.plist 的 WorkspacePath，取不到时返回 DerivedData 子目录）
    public static func otherProject(owning uuids: Set<String>, appName: String, excluding derivedDataPath: String) -> String? {
        guard !uuids.isEmpty, !appName.isEmpty else {
            return nil
        }
        let fileManager = FileManager.default
        let ours = (derivedDataPath as NSString).standardizingPath
        let root = (ours as NSString).deletingLastPathComponent
        for sibling in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] {
            let siblingPath = (root as NSString).appendingPathComponent(sibling)
            guard siblingPath != ours else {
                continue
            }
            let productsDir = siblingPath + "/Build/Products"
            for configuration in (try? fileManager.contentsOfDirectory(atPath: productsDir)) ?? [] {
                let appPath = productsDir + "/" + configuration + "/" + appName
                guard fileManager.fileExists(atPath: appPath), let product = product(atPath: appPath) else {
                    continue
                }
                if !product.uuids.isDisjoint(with: uuids) {
                    let info = NSDictionary(contentsOfFile: siblingPath + "/info.plist")
                    return info?["WorkspacePath"] as? String ?? siblingPath
                }
            }
        }
        return nil
    }

    private static func modificationDate(of path: String) -> Date? {
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func cachedUUIDs(ofFile path: String, modified: Date) -> Set<String> {
        lock.lock()
        if let cached = uuidCache[path], cached.date == modified {
            lock.unlock()
            return cached.uuids
        }
        lock.unlock()
        let uuids = machOUUIDs(atPath: path)
        lock.lock()
        uuidCache[path] = (modified, uuids)
        lock.unlock()
        return uuids
    }

    // MARK: - Mach-O

    /// 读取 Mach-O（含 fat 包的每个切片）的 LC_UUID
    public static func machOUUIDs(atPath path: String) -> Set<String> {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return []
        }
        defer { try? handle.close() }
        guard let head = read(handle, offset: 0, count: 8), head.count == 8 else {
            return []
        }
        let magicBE = head.uint32(at: 0, bigEndian: true)
        // fat 头固定为大端：FAT_MAGIC 0xcafebabe / FAT_MAGIC_64 0xcafebabf
        if magicBE == 0xcafe_babe || magicBE == 0xcafe_babf {
            let is64 = magicBE == 0xcafe_babf
            let count = Int(head.uint32(at: 4, bigEndian: true))
            let entrySize = is64 ? 32 : 20
            // 短读（二进制正在被链接器改写）时 table 不足，按完整长度校验，避免 subdata 越界崩溃
            guard count > 0, count < 32, let table = read(handle, offset: 8, count: count * entrySize),
                  table.count == count * entrySize else {
                return []
            }
            var result = Set<String>()
            for i in 0 ..< count {
                let base = i * entrySize
                let offset = is64 ? table.uint64(at: base + 8, bigEndian: true) : UInt64(table.uint32(at: base + 8, bigEndian: true))
                result.formUnion(sliceUUIDs(handle, offset: offset))
            }
            return result
        }
        return sliceUUIDs(handle, offset: 0)
    }

    private static func sliceUUIDs(_ handle: FileHandle, offset: UInt64) -> Set<String> {
        // mach_header_64：magic(4) cputype(4) cpusubtype(4) filetype(4) ncmds(4) sizeofcmds(4) flags(4) reserved(4)
        guard let header = read(handle, offset: offset, count: 32), header.count == 32,
              header.uint32(at: 0, bigEndian: false) == 0xfeed_facf else {
            return []
        }
        let commandCount = Int(header.uint32(at: 16, bigEndian: false))
        let commandsSize = Int(header.uint32(at: 20, bigEndian: false))
        guard commandsSize > 0, commandsSize < 16 * 1024 * 1024,
              let commands = read(handle, offset: offset + 32, count: commandsSize), commands.count == commandsSize else {
            return []
        }
        var cursor = 0
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= commands.count else {
                break
            }
            let cmd = commands.uint32(at: cursor, bigEndian: false)
            let size = Int(commands.uint32(at: cursor + 4, bigEndian: false))
            // LC_UUID = 0x1b：cmd(4) cmdsize(4) uuid(16)
            if cmd == 0x1b, cursor + 24 <= commands.count {
                let bytes = commands.subdata(in: commands.startIndex + cursor + 8 ..< commands.startIndex + cursor + 24)
                let uuid = bytes.withUnsafeBytes { raw -> String in
                    let tuple = raw.load(as: uuid_t.self)
                    return UUID(uuid: tuple).uuidString
                }
                return [uuid]
            }
            guard size >= 8 else {
                break
            }
            cursor += size
        }
        return []
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

private extension Data {
    func uint32(at offset: Int, bigEndian: Bool) -> UInt32 {
        let value = subdata(in: startIndex + offset ..< startIndex + offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    func uint64(at offset: Int, bigEndian: Bool) -> UInt64 {
        let value = subdata(in: startIndex + offset ..< startIndex + offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return bigEndian ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
    }
}
