import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - Status model

struct AgentStatus {
    var pin: String
    var sessionId: String?
    var localIPs: [String]
    var connectedClients: Int
    var webEnabled: Bool = false
}

// MARK: - MenuBarController

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var status = AgentStatus(pin: "…", sessionId: nil, localIPs: [], connectedClients: 0)

    // Called by RemoterAgent when something changes
    func update(_ newStatus: AgentStatus) {
        status = newStatus
        refresh()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // メニューバーのみ、Dockに表示しない
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            // 使用 SF Symbol 作为图标，确保在所有 macOS 版本渲染正常
            if let img = NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: "Remoter") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "R"
            }
            btn.toolTip = "Remoter"
        }
        refresh()
        // 启动时主动申请屏幕录制权限，确保弹框在前台出现
        requestScreenCapturePermission()
        // 辅助功能权限：CGEvent.post 需要此权限才能注入鼠标/键盘事件
        requestAccessibilityPermission()
    }

    // 主动触发屏幕录制权限申请，避免在后台连接时弹框被 macOS 忽略
    private func requestScreenCapturePermission() {
        // Step 1: TCC 权限检查（同步，不阻塞 UI）
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            ConnectionLogger.shared.logPermission(event: "screen_capture_denied")
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "请前往「系统设置 → 隐私与安全性 → 屏幕与系统录音」，打开 RemoterAgent 的开关，然后重启本 app。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        ConnectionLogger.shared.logPermission(event: "screen_capture_granted")

        // Step 2: macOS 26 每次 app 启动都需要一次「录制会话授权」
        // 在 app 启动时（用户在 Mac 前）主动触发，让用户点允许。
        // 这样后续客户端连接时不再出现弹框。
        DispatchQueue.global(qos: .userInitiated).async {
            if CGDisplayCreateImage(CGMainDisplayID()) != nil {
                ConnectionLogger.shared.logPermission(event: "session_auth_ok")
            } else {
                ConnectionLogger.shared.logPermission(event: "session_auth_failed")
            }
        }
    }

    private func requestAccessibilityPermission() {
        // 已授权：直接返回，不弹任何对话框
        if AXIsProcessTrusted() {
            ConnectionLogger.shared.logPermission(event: "accessibility_granted")
            return
        }
        // 未授权：触发系统弹框（首次运行时）
        ConnectionLogger.shared.logPermission(event: "accessibility_denied")
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        )
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "请前往「系统设置 → 隐私与安全性 → 辅助功能」，打开 RemoterAgent 的开关，然后重启本 app。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }

    // MARK: - Menu build

    private func refresh() {
        let isConnected = status.connectedClients > 0

        // 图标：连接中切换为活跃状态 SF Symbol
        if let btn = statusItem?.button {
            let symbolName = isConnected ? "display.and.arrow.down.fill" : "display.and.arrow.down"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Remoter") {
                img.isTemplate = true
                btn.image = img
            }
        }

        let menu = NSMenu()

        // ── 连接状态 ──────────────────────────────────────────
        let stateLabel = isConnected
            ? "● \(status.connectedClients) 个客户端已连接"
            : "○ 等待连接…"
        let stateItem = NSMenuItem(title: stateLabel, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        stateItem.attributedTitle = NSAttributedString(
            string: stateLabel,
            attributes: [.foregroundColor: isConnected ? NSColor.systemGreen : NSColor.secondaryLabelColor]
        )
        menu.addItem(stateItem)

        menu.addItem(.separator())

        // ── PIN（点击复制）────────────────────────────────────
        menu.addItem(copyMenuItem(label: "PIN：\(status.pin)", value: status.pin,
                                  tag: MenuTag.pin.rawValue))

        // ── 会话 ID（中继模式）───────────────────────────────
        if let sid = status.sessionId {
            menu.addItem(copyMenuItem(label: "会话 ID：\(sid)", value: sid,
                                      tag: MenuTag.session.rawValue))
        }

        // ── 局域网地址 ────────────────────────────────────────
        if !status.localIPs.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "局域网地址", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for ip in status.localIPs {
                let item = NSMenuItem(title: "  ws://\(ip):7788",
                                      action: #selector(copyIP(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ip
                menu.addItem(item)
            }
        }

        // ── Web 客户端地址（仅当 bundle 内嵌了 web 产物时显示）────
        if status.webEnabled && !status.localIPs.isEmpty {
            menu.addItem(.separator())
            let webHeader = NSMenuItem(title: "Web 客户端", action: nil, keyEquivalent: "")
            webHeader.isEnabled = false
            menu.addItem(webHeader)
            for ip in status.localIPs {
                let item = NSMenuItem(title: "  http://\(ip):7799",
                                      action: #selector(copyWebURL(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ip
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "在 Finder 中显示日志",
                                 action: #selector(showLogInFinder),
                                 keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Remoter",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func copyMenuValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        sender.title = "✓ 已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func showLogInFinder() {
        let fileURL = ConnectionLogger.shared.logFileURL
        let dirURL  = fileURL.deletingLastPathComponent()
        // 目录不存在时先创建
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // 文件存在：在 Finder 中高亮选中
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            // 文件不存在（尚无连接日志）：打开目录
            NSWorkspace.shared.open(dirURL)
        }
    }

    @objc private func copyIP(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ws://\(ip):7788", forType: .string)
    }

    @objc private func copyWebURL(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(ip):7799", forType: .string)
    }

    // MARK: - Helpers

    private func copyMenuItem(label: String, value: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: label,
                              action: #selector(copyMenuValue(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.tag = tag
        item.toolTip = "点击复制"
        return item
    }

    private enum MenuTag: Int {
        case pin = 1, session = 2
    }
}
