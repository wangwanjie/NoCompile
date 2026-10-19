//
//  ClientCompatibility.swift
//  判断已连接的客户端与当前 Mac 端是否匹配。
//
//  典型问题：用 bundle 方式接入时，nocompile_copy_bundle.sh 在 App 构建时把 Mac 端随附的 bundle 拷进 App 包；
//  之后 Mac 端升级了，App 却没有重新编译，包里仍是旧 bundle。新旧两端行为不一致，可能注入失败甚至卡住。
//  检测依据是客户端上报的「客户端修订号」（clientRevision），只在客户端代码或协议发生不兼容变化时才递增，
//  与发版的版本号无关：只改 Mac 端界面等不影响配对的发版，不会要求用户重新编译 App。
//

import Foundation

public enum ClientCompatibility {

    /// 尚未上报修订号的旧客户端中，与当前修订号兼容的版本（0.2.4 是引入修订号前的最后一个版本）
    private static let legacyCompatibleVersions: Set<String> = ["0.2.4"]

    /// 返回不兼容原因；兼容返回 nil
    public static func issue(for info: [String: Any]) -> String? {
        if let protocolVersion = info["protocol"] as? Int, protocolVersion != NCProtocol.version {
            return "App 内的 NoCompile 客户端协议版本为 \(protocolVersion)，Mac 端为 \(NCProtocol.version)"
        }
        let version = (info["clientVersion"] as? String) ?? ""
        if let revision = info["clientRevision"] as? Int {
            if revision != NCProtocol.clientRevision {
                return "App 内的 NoCompile 客户端（版本 \(version)，修订 \(revision)）与当前 Mac 端（版本 \(NCProtocol.clientVersion)，修订 \(NCProtocol.clientRevision)）不兼容"
            }
            return nil
        }
        // 旧客户端没有修订号：按已知兼容的版本放行，其余视为过期
        if version.isEmpty {
            return "App 内的 NoCompile 客户端是旧版本（未上报版本号），与当前 Mac 端 \(NCProtocol.clientVersion) 不兼容"
        }
        if !legacyCompatibleVersions.contains(version) {
            return "App 内的 NoCompile 客户端版本为 \(version)，与当前 Mac 端 \(NCProtocol.clientVersion) 不兼容"
        }
        return nil
    }
}
