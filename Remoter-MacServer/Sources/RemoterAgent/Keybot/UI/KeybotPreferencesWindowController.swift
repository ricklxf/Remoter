import Cocoa
import SwiftUI

final class KeybotPreferencesWindowController {
    static let shared = KeybotPreferencesWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        let present = { [weak self] in
            guard let self else { return }
            if let w = self.window {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
                return
            }

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "键位映射设置 (Keybot)"
            w.titlebarAppearsTransparent = false
            w.toolbarStyle = .unified
            w.contentView = NSHostingView(rootView: KeybotPreferencesView())
            w.minSize = NSSize(width: 620, height: 440)
            w.center()
            w.isReleasedWhenClosed = false
            self.window = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async {
                present()
            }
        }
    }
}
