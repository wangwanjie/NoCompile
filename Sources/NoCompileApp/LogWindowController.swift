//
//  LogWindowController.swift
//  日志窗口：展示引擎与 App 的实时日志
//

import AppKit

final class LogWindowController: NSWindowController {

    private let textView = NSTextView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "NoCompile 日志"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let window else { return }
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        scrollView.documentView = textView
        window.contentView = scrollView
    }

    func append(_ message: String, level: Int) {
        let color: NSColor
        switch level {
        case 1: color = .systemGreen
        case 2: color = .systemOrange
        case 3: color = .systemRed
        default: color = .labelColor
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let attributed = NSAttributedString(string: line, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ])
        textView.textStorage?.append(attributed)
        textView.scrollToEndOfDocument(nil)
    }

    func clear() {
        textView.string = ""
    }
}
