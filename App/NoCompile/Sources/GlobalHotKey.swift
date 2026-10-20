//
//  GlobalHotKey.swift
//  全局快捷键：在任何 App（通常是 Xcode）中按下即触发「检查改动」。
//  使用 Carbon 的 RegisterEventHotKey，不需要辅助功能权限，也不会拦截其他按键。
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {

    static let shared = GlobalHotKey()

    /// 热键按下时在主线程回调
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4E43_484B   // "NCHK"

    private init() {}

    /// 注册或更换热键；.off 表示注销。返回是否注册成功（组合已被其他 App 占用时失败）
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let (keyCode, modifiers) = Self.carbonKey(for: preset) else {
            return true
        }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            guard hotKeyID.signature == hotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                hotKey.onPress?()
            }
            return noErr
        }, 1, &eventType, context, &handlerRef)
    }

    private static func carbonKey(for preset: HotKeyPreset) -> (UInt32, UInt32)? {
        let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
        switch preset {
        case .off:
            return nil
        case .controlOptionCommandR:
            return (UInt32(kVK_ANSI_R), controlOptionCommand)
        case .shiftOptionCommandR:
            return (UInt32(kVK_ANSI_R), UInt32(shiftKey | optionKey | cmdKey))
        case .controlOptionCommandH:
            return (UInt32(kVK_ANSI_H), controlOptionCommand)
        case .controlOptionCommandJ:
            return (UInt32(kVK_ANSI_J), controlOptionCommand)
        }
    }
}
