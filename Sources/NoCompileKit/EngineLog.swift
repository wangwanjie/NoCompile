//
//  EngineLog.swift
//  引擎日志：按分类加 emoji 与标签，控制台按级别着色，命令行与日志文件用同样的前缀，一眼区分来源
//

import Foundation

/// 日志分类
public enum LogCategory: String, CaseIterable, Identifiable {
    case general     // 引擎启动、就绪等
    case watch       // 文件改动检测
    case build       // 构建日志 / 构建清单解析
    case compile     // 重编
    case inject      // 推送与注入结果
    case resource    // 资源热重载
    case connection  // App 连接、断开、握手
    case device      // 设备切换、补推
    case app         // App 端转发的日志

    public var id: String { rawValue }

    /// 行首 emoji
    public var emoji: String {
        switch self {
        case .general: return "⚙️"
        case .watch: return "👀"
        case .build: return "📦"
        case .compile: return "🔨"
        case .inject: return "⚡"
        case .resource: return "🖼"
        case .connection: return "🔌"
        case .device: return "📱"
        case .app: return "💬"
        }
    }

    /// 分类标签
    public var title: String {
        switch self {
        case .general: return "引擎"
        case .watch: return "改动"
        case .build: return "构建"
        case .compile: return "编译"
        case .inject: return "注入"
        case .resource: return "资源"
        case .connection: return "连接"
        case .device: return "设备"
        case .app: return "App"
        }
    }
}

/// 一条引擎日志
public struct EngineLog {
    /// 0 信息 / 1 成功 / 2 警告 / 3 错误
    public let level: Int
    public let category: LogCategory
    public let message: String
    /// App 端日志的来源（App 名 @ 设备），其他分类为 nil
    public let source: String?

    public init(level: Int, category: LogCategory, message: String, source: String? = nil) {
        self.level = level
        self.category = category
        self.message = message
        self.source = source
    }

    /// 级别标记：错误 ❌、警告 ⚠️、成功 ✅，普通信息为空
    public var levelMark: String {
        switch level {
        case 1: return "✅"
        case 2: return "⚠️"
        case 3: return "❌"
        default: return ""
        }
    }

    /// 纯文本：「emoji 分类 │ 级别标记 [来源] 正文」，用于命令行与日志文件
    public var plainText: String {
        var text = "\(category.emoji) \(category.title) │ "
        if !levelMark.isEmpty {
            text += levelMark + " "
        }
        if let source, !source.isEmpty {
            text += "[\(source)] "
        }
        return text + message
    }
}
