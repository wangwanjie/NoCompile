//
//  ExPlayerState.swift
//  带关联值的枚举（跨模块）
//

import Foundation

public enum ExPlayerState: Equatable {
    case idle
    case playing(track: String, progress: Double)
    case failed(code: Int)

    public var label: String {
        switch self {
        case .idle:
            return "idle"
        case .playing(let track, let progress):
            return "playing \(track) \(Int(progress * 100))% @@v1@@"
        case .failed(let code):
            return "failed \(code)"
        }
    }
}
