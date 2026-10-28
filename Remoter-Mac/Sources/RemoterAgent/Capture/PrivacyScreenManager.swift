import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Privacy Screen / Curtain Mode
/// Covers the physical display with an opaque secure overlay to prevent local snooping,
/// while allowing ScreenCaptureKit to exclude the overlay so the remote client sees the desktop clearly.
public final class PrivacyScreenManager: @unchecked Sendable {
    public static let shared = PrivacyScreenManager()

    private var overlayWindows: [NSWindow] = []
    public private(set) var isEnabled = false
    private let lock = NSLock()

    public init() {}

    @MainActor
    public func enable() {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnabled else { return }
        isEnabled = true

        let screens = NSScreen.screens
        for screen in screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false

            let frame = NSRect(origin: .zero, size: screen.frame.size)
            let container = NSView(frame: frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)

            let badge = NSView(frame: NSRect(x: (frame.width - 440) / 2, y: (frame.height - 200) / 2, width: 440, height: 200))
            badge.wantsLayer = true
            badge.layer?.backgroundColor = CGColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 0.95)
            badge.layer?.cornerRadius = 16
            badge.layer?.borderWidth = 1.5
            badge.layer?.borderColor = CGColor(red: 0.25, green: 0.40, blue: 0.85, alpha: 0.8)

            let title = NSTextField(labelWithString: "🔒 Remoter 防窥隐私模式")
            title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
            title.textColor = .white
            title.alignment = .center
            title.frame = NSRect(x: 20, y: 130, width: 400, height: 32)
            badge.addSubview(title)

            let desc = NSTextField(labelWithString: "远端会话正在操作中，本地屏幕已安全遮盖。\n可在主控端工具栏随时退出防窥模式。")
            desc.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            desc.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
            desc.alignment = .center
            desc.frame = NSRect(x: 20, y: 35, width: 400, height: 80)
            badge.addSubview(desc)

            container.addSubview(badge)
            window.contentView = container
            window.orderFrontRegardless()
            overlayWindows.append(window)
        }

        ConnectionLogger.shared.logStep(sessionId: "privacy", step: "privacy_enabled", detail: "screens=\(screens.count)")
    }

    @MainActor
    public func disable() {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }
        isEnabled = false

        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        ConnectionLogger.shared.logStep(sessionId: "privacy", step: "privacy_disabled")
    }

    public func getOverlayWindowIDs() -> [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        return overlayWindows.map { CGWindowID($0.windowNumber) }
    }
}
