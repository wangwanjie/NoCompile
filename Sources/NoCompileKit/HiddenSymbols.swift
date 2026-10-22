//
//  HiddenSymbols.swift
//  桥接 App 未导出的符号。
//
//  有的工程在 Debug 下也只导出少数符号（EXPORTED_SYMBOLS_FILE 只列 _main、-fvisibility=hidden 等），
//  App 里定义的类、函数、常量都变成了 "non-external (was a private external)"。注入的 dylib 以
//  -undefined dynamic_lookup 链接，引用这些符号时 dyld 在已加载镜像的导出表里找不到，dlopen 直接失败：
//  symbol not found in flat namespace '_OBJC_CLASS_$_Foo'。
//
//  这些符号仍留在 DerivedData 中 App 二进制的符号表里（Debug 构建不剥离），地址加上 App 运行时的 slide
//  就是它们在进程里的真实地址。这里为注入 dylib 用到的这类符号生成一个只含「绝对地址导出」的小 dylib
//  （汇编里 `"_sym" = 0x地址`，链接器把它导出为 EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE），
//  客户端先以 RTLD_GLOBAL 加载它，再加载注入 dylib，dyld 按扁平命名空间查找时就能绑定到 App 里的原对象。
//

import Foundation

/// 连接上来的 App 中的一个镜像（主程序或 .debug.dylib）：DerivedData 中对应的二进制、LC_UUID 与运行时 slide
public struct AppImage {
    public let binaryPath: String
    public let uuid: String
    /// 客户端上报的 slide；旧客户端不上报时为 nil，此时无法算出运行时地址
    public let slide: Int64?

    public init(binaryPath: String, uuid: String, slide: Int64?) {
        self.binaryPath = binaryPath
        self.uuid = uuid
        self.slide = slide
    }
}

/// 一次桥接的结果
public struct SymbolShimPlan {
    /// 符号名 → 运行时地址
    public var addresses: [String: UInt64] = [:]
    /// App 里存在、但因客户端没有上报 slide 而无法桥接的符号
    public var missingSlide: [String] = []
}

public enum HiddenSymbols {

    // Mach-O 常量（<mach-o/nlist.h>、<mach-o/loader.h>）
    private static let nStab: UInt8 = 0xe0
    private static let nPext: UInt8 = 0x10
    private static let nTypeMask: UInt8 = 0x0e
    private static let nExt: UInt8 = 0x01
    private static let nUndf: UInt8 = 0x0
    private static let nSect: UInt8 = 0xe
    private static let dynamicLookupOrdinal: UInt16 = 0xfe
    private static let lcSymtab: UInt32 = 0x2
    private static let lcUUID: UInt32 = 0x1b
    private static let magic64: UInt32 = 0xfeed_facf

    private static let lock = NSLock()
    /// 二进制（路径|修改时间|大小|UUID）→ 已查过的符号：找到的记地址，没找到的记 nil。
    /// 大型 App 的符号表有近千万项，只缓存查过的名字，不缓存整张表
    private static var cache: [String: [String: UInt64?]] = [:]

    /// 规划桥接：取 dylib 中按扁平命名空间查找的未定义符号，在 App 镜像的符号表里找出「定义了但未导出」的那些
    public static func plan(dylibPath: String, images: [AppImage]) -> SymbolShimPlan {
        var plan = SymbolShimPlan()
        var wanted = Set(dynamicLookupUndefinedSymbols(ofFile: dylibPath))
        guard !wanted.isEmpty else {
            return plan
        }
        for image in images where !wanted.isEmpty {
            let found = resolve(wanted, in: image)
            for (name, value) in found {
                wanted.remove(name)
                guard let slide = image.slide else {
                    plan.missingSlide.append(name)
                    continue
                }
                plan.addresses[name] = UInt64(bitPattern: Int64(bitPattern: value) &+ slide)
            }
        }
        plan.missingSlide.sort()
        return plan
    }

    /// 生成桥接 dylib 的汇编源码。名字里含引号、反斜杠或换行的符号无法安全写进汇编，跳过
    public static func assemblySource(for addresses: [String: UInt64]) -> String {
        var lines: [String] = ["// NoCompile：把 App 未导出的符号按运行时地址导出（绝对符号）"]
        for name in addresses.keys.sorted() {
            guard let value = addresses[name], !name.contains("\""), !name.contains("\\"), !name.contains("\n") else {
                continue
            }
            lines.append(".globl \"\(name)\"")
            lines.append("\"\(name)\" = 0x\(String(value, radix: 16))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 注入 dylib 的未定义符号

    /// dylib 中库序号为 DYNAMIC_LOOKUP_ORDINAL 的未定义符号（-undefined dynamic_lookup 留给 dyld 扁平查找的那些）。
    /// 链接到系统库的符号按两级命名空间绑定到指定库，不经过桥接 dylib，不必处理
    static func dynamicLookupUndefinedSymbols(ofFile path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let symtab = symtabCommand(in: data, sliceOffset: 0) else {
            return []
        }
        var result: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0 ..< Int(symtab.nsyms) {
                let entry = Int(symtab.symoff) + i * 16
                guard entry + 16 <= raw.count else {
                    break
                }
                let type = raw[entry + 4]
                let desc = raw.loadUnaligned(fromByteOffset: entry + 6, as: UInt16.self)
                let value = raw.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self)
                // 未定义的外部符号，n_value 不为 0 的是 common 符号，跳过
                guard type & nStab == 0, type & nTypeMask == nUndf, type & nExt != 0, value == 0,
                      (desc >> 8) & 0xff == dynamicLookupOrdinal else {
                    continue
                }
                let strx = Int(raw.loadUnaligned(fromByteOffset: entry, as: UInt32.self))
                if let name = cString(in: raw, at: Int(symtab.stroff) + strx, limit: Int(symtab.stroff + symtab.strsize)) {
                    result.append(name)
                }
            }
        }
        return result
    }

    // MARK: - App 二进制的符号表

    /// 在镜像对应的二进制中查找这些符号：只认「曾是外部符号、被隐藏」的定义（N_PEXT 置位、N_EXT 清零）。
    /// 同名出现多个不同地址的视为有歧义，不桥接
    static func resolve(_ names: Set<String>, in image: AppImage) -> [String: UInt64] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: image.binaryPath)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes?[.size] as? Int ?? 0
        let key = "\(image.binaryPath)|\(modified)|\(size)|\(image.uuid)"

        lock.lock()
        let known = cache[key] ?? [:]
        lock.unlock()
        var result: [String: UInt64] = [:]
        var unknown = Set<String>()
        for name in names {
            if let entry = known[name] {
                if let value = entry {
                    result[name] = value
                }
            } else {
                unknown.insert(name)
            }
        }
        guard !unknown.isEmpty else {
            return result
        }
        let start = Date()
        let scanned = scan(binaryPath: image.binaryPath, uuid: image.uuid, names: unknown)
        Diagnostics.shared.log("符号桥接", "扫描 \((image.binaryPath as NSString).lastPathComponent) 的符号表查找 \(unknown.count) 个符号，"
            + "找到 \(scanned?.count ?? 0) 个未导出的定义，用时 \(String(format: "%.2f", Date().timeIntervalSince(start)))s",
            level: .debug)
        guard let scanned else {
            // 读不了（文件不存在、UUID 不匹配）：不缓存，下次重试
            return result
        }
        lock.lock()
        var updated = cache[key] ?? [:]
        for name in unknown {
            updated[name] = scanned[name]
        }
        cache[key] = updated
        lock.unlock()
        result.merge(scanned) { current, _ in current }
        return result
    }

    private struct SymtabCommand {
        let symoff: UInt32
        let nsyms: UInt32
        let stroff: UInt32
        let strsize: UInt32
        let uuid: String?
    }

    /// 扫描二进制中 LC_UUID 与 uuid 一致的切片。返回 nil 表示没有可读的匹配切片
    private static func scan(binaryPath: String, uuid: String, names: Set<String>) -> [String: UInt64]? {
        guard let handle = FileHandle(forReadingAtPath: binaryPath) else {
            return nil
        }
        defer { try? handle.close() }
        guard let sliceOffset = matchingSliceOffset(handle, uuid: uuid),
              let header = read(handle, offset: sliceOffset, count: 32), header.count == 32 else {
            return nil
        }
        let commandsSize = Int(header.le32(at: 20))
        guard commandsSize > 0, commandsSize < 16 * 1024 * 1024,
              let commands = read(handle, offset: sliceOffset, count: 32 + commandsSize),
              let symtab = symtabCommand(in: commands, sliceOffset: 0) else {
            return nil
        }
        // 字符串表整块读入（大型 App 约 200MB，用完即释放）；nlist 分块读，只看隐藏的定义
        guard let strings = read(handle, offset: sliceOffset + UInt64(symtab.stroff), count: Int(symtab.strsize)),
              strings.count == Int(symtab.strsize) else {
            return nil
        }
        // 按字节长度分组，扫描时先比长度，只有长度相同才逐字节比较
        var wantedByLength: [Int: [[UInt8]]] = [:]
        for name in names {
            let bytes = Array(name.utf8)
            wantedByLength[bytes.count, default: []].append(bytes)
        }
        var found: [String: UInt64] = [:]
        var ambiguous = Set<String>()
        let chunkEntries = 256 * 1024
        var index = 0
        let total = Int(symtab.nsyms)
        strings.withUnsafeBytes { (strtab: UnsafeRawBufferPointer) in
            while index < total {
                let count = min(chunkEntries, total - index)
                guard let chunk = read(handle, offset: sliceOffset + UInt64(symtab.symoff) + UInt64(index * 16), count: count * 16),
                      chunk.count == count * 16 else {
                    break
                }
                chunk.withUnsafeBytes { (entries: UnsafeRawBufferPointer) in
                    for i in 0 ..< count {
                        let base = i * 16
                        let type = entries[base + 4]
                        guard type & nStab == 0, type & nTypeMask == nSect, type & nExt == 0, type & nPext != 0 else {
                            continue
                        }
                        let strx = Int(entries.loadUnaligned(fromByteOffset: base, as: UInt32.self))
                        guard strx < strtab.count, let start = strtab.baseAddress?.advanced(by: strx) else {
                            continue
                        }
                        let length = strnlen(start.assumingMemoryBound(to: CChar.self), strtab.count - strx)
                        guard let candidates = wantedByLength[length] else {
                            continue
                        }
                        for candidate in candidates where memcmp(start, candidate, length) == 0 {
                            let name = String(decoding: candidate, as: UTF8.self)
                            let value = entries.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self)
                            if let existing = found[name], existing != value {
                                ambiguous.insert(name)
                            } else {
                                found[name] = value
                            }
                            break
                        }
                    }
                }
                index += count
            }
        }
        for name in ambiguous {
            found[name] = nil
            Diagnostics.shared.log("符号桥接", "\(name) 在 \((binaryPath as NSString).lastPathComponent) 中有多个定义，不桥接", level: .warning)
        }
        return found
    }

    /// fat 包中找 LC_UUID 一致的切片偏移；thin 文件 UUID 一致时返回 0
    private static func matchingSliceOffset(_ handle: FileHandle, uuid: String) -> UInt64? {
        guard let head = read(handle, offset: 0, count: 8), head.count == 8 else {
            return nil
        }
        let magicBE = head.be32(at: 0)
        var offsets: [UInt64] = []
        if magicBE == 0xcafe_babe || magicBE == 0xcafe_babf {
            let is64 = magicBE == 0xcafe_babf
            let count = Int(head.be32(at: 4))
            let entrySize = is64 ? 32 : 20
            // 短读（文件正在被链接器改写）时 table 不足，按完整长度校验，避免越界读取
            guard count > 0, count < 32, let table = read(handle, offset: 8, count: count * entrySize),
                  table.count == count * entrySize else {
                return nil
            }
            for i in 0 ..< count {
                let base = i * entrySize
                offsets.append(is64 ? table.be64(at: base + 8) : UInt64(table.be32(at: base + 8)))
            }
        } else {
            offsets = [0]
        }
        for offset in offsets {
            guard let header = read(handle, offset: offset, count: 32), header.count == 32, header.le32(at: 0) == magic64 else {
                continue
            }
            let commandsSize = Int(header.le32(at: 20))
            guard commandsSize > 0, commandsSize < 16 * 1024 * 1024,
                  let commands = read(handle, offset: offset, count: 32 + commandsSize),
                  let symtab = symtabCommand(in: commands, sliceOffset: 0) else {
                continue
            }
            if symtab.uuid?.caseInsensitiveCompare(uuid) == .orderedSame {
                return offset
            }
        }
        return nil
    }

    /// 解析 mach_header_64 之后的 load command，取 LC_SYMTAB 与 LC_UUID
    private static func symtabCommand(in data: Data, sliceOffset: Int) -> SymtabCommand? {
        guard data.count >= sliceOffset + 32, data.le32(at: sliceOffset) == magic64 else {
            return nil
        }
        let commandCount = Int(data.le32(at: sliceOffset + 16))
        var cursor = sliceOffset + 32
        var symtab: (UInt32, UInt32, UInt32, UInt32)?
        var uuid: String?
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= data.count else {
                break
            }
            let cmd = data.le32(at: cursor)
            let size = Int(data.le32(at: cursor + 4))
            if cmd == lcSymtab, cursor + 24 <= data.count {
                symtab = (data.le32(at: cursor + 8), data.le32(at: cursor + 12), data.le32(at: cursor + 16), data.le32(at: cursor + 20))
            } else if cmd == lcUUID, cursor + 24 <= data.count {
                let bytes = data.subdata(in: data.startIndex + cursor + 8 ..< data.startIndex + cursor + 24)
                uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)).uuidString }
            }
            guard size >= 8 else {
                break
            }
            cursor += size
        }
        guard let symtab else {
            return nil
        }
        return SymtabCommand(symoff: symtab.0, nsyms: symtab.1, stroff: symtab.2, strsize: symtab.3, uuid: uuid)
    }

    private static func cString(in raw: UnsafeRawBufferPointer, at offset: Int, limit: Int) -> String? {
        let end = min(limit, raw.count)
        guard offset >= 0, offset < end else {
            return nil
        }
        var cursor = offset
        while cursor < end, raw[cursor] != 0 {
            cursor += 1
        }
        guard cursor > offset else {
            return nil
        }
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset ..< cursor]), as: UTF8.self)
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

/// 越界时返回 0 而不是读到缓冲区之外：调用方都会再校验魔数 / 命令大小，0 会被当作无效数据丢弃
private extension Data {
    func le32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            return 0
        }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func be32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            return 0
        }
        return withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func be64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            return 0
        }
        return withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
