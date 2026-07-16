import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit

// MARK: - Status model

struct AgentStatus {
    var pin: String
    var sessionId: String?
    var localIPs: [String]
    var vpnIPs: [String] = []   // Tailscale (100.x.x.x) / ZeroTier (zt*)
    var connectedClients: Int
    var webEnabled: Bool = false
    var port: UInt16 = 7788
    var localHostname: String = ""  // mDNS .local 主机名，固定不随 IP 变化
    var inputLocked: Bool = false
}

// MARK: - MenuBarController

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var status = AgentStatus(pin: "…", sessionId: nil, localIPs: [], connectedClients: 0)

    // Set by main.swift to forward file sends to agent
    var onSendFile: ((URL) -> Void)?

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
        // 依次申请权限：先屏幕录制，再辅助功能，避免同时弹两个框
        Task {
            await requestScreenCapturePermission()
            await MainActor.run { requestAccessibilityPermission() }
        }
    }

    // 用 ScreenCaptureKit 触发屏幕录制权限（包含 macOS 15+ 的会话授权弹窗）
    // 返回后再请求辅助功能权限，保证两个弹框不同时出现
    private func requestScreenCapturePermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            ConnectionLogger.shared.logPermission(event: "screen_capture_granted")
        } catch {
            ConnectionLogger.shared.logPermission(event: "screen_capture_denied")
            await MainActor.run {
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
            }
        }
    }

    private func requestAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        )
        ConnectionLogger.shared.logPermission(event: trusted ? "accessibility_granted" : "accessibility_denied")
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

        // ── 键鼠锁定：显式解锁入口 ─────────────────────────────
        // Control+Option+Command+Esc also unlocks, but that combo isn't
        // discoverable from the menu bar UI alone — this is the "I forgot
        // the shortcut" / "just point and click" fallback. Only shown while
        // actually locked so it doesn't clutter the normal menu.
        if status.inputLocked {
            let unlockItem = NSMenuItem(title: "🔓 解除键鼠锁定", action: #selector(unlockInput), keyEquivalent: "")
            unlockItem.target = self
            unlockItem.attributedTitle = NSAttributedString(
                string: "🔓 解除键鼠锁定",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(unlockItem)
        }

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
                let item = NSMenuItem(title: "  wss://\(ip):7788",
                                      action: #selector(copyIP(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ip
                menu.addItem(item)
            }
        }

        // ── VPN 地址（Tailscale / ZeroTier）─────────────────────
        if !status.vpnIPs.isEmpty {
            menu.addItem(.separator())
            let vpnHeader = NSMenuItem(title: "VPN 地址 (Tailscale/ZeroTier)", action: nil, keyEquivalent: "")
            vpnHeader.isEnabled = false
            menu.addItem(vpnHeader)
            for ip in status.vpnIPs {
                let item = NSMenuItem(title: "  wss://\(ip):7788",
                                      action: #selector(copyIP(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ip
                menu.addItem(item)
            }
        }

        // ── Web 客户端地址（仅当 bundle 内嵌了 web 产物时显示）────
        if status.webEnabled {
            menu.addItem(.separator())
            let webHeader = NSMenuItem(title: "Web 客户端（浏览器）", action: nil, keyEquivalent: "")
            webHeader.isEnabled = false
            menu.addItem(webHeader)
            // 优先显示 .local 主机名（固定不变，推荐用来信任证书）
            if !status.localHostname.isEmpty {
                let item = NSMenuItem(title: "  https://\(status.localHostname):\(status.port)/",
                                      action: #selector(copyWebURL(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = "\(status.localHostname):\(status.port)"
                menu.addItem(item)
            }
            for ip in status.localIPs {
                let item = NSMenuItem(title: "  https://\(ip):\(status.port)/",
                                      action: #selector(copyWebURL(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = "\(ip):\(status.port)"
                menu.addItem(item)
            }
        }

        // ── 发送文件给客户端（有连接时显示）────────────────────
        if isConnected {
            menu.addItem(.separator())
            let sendItem = NSMenuItem(title: "发送文件给客户端…",
                                      action: #selector(pickAndSendFile),
                                      keyEquivalent: "")
            sendItem.target = self
            menu.addItem(sendItem)
        }

        // ── 辅助功能权限状态 ────────────────────────────────────
        menu.addItem(.separator())
        if AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "✓ 辅助功能已授权", action: nil, keyEquivalent: "")
            axItem.isEnabled = false
            menu.addItem(axItem)
        } else {
            let axItem = NSMenuItem(title: "⚠ 辅助功能未授权（点击授权）",
                                    action: #selector(openAccessibilitySettings),
                                    keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
        }

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "在 Finder 中显示日志",
                                 action: #selector(showLogInFinder),
                                 keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let settingsItem = NSMenuItem(title: "设置端口 / 中继…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "Remoter v\(kAppVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Remoter",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        var diskCfg = AgentConfig.load()

        let alert = NSAlert()
        alert.messageText = "Remoter 设置"
        alert.informativeText = "修改端口后服务将自动重启"
        alert.addButton(withTitle: "保存并重启")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 108))

        func label(_ s: String, y: CGFloat) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.frame = NSRect(x: 0, y: y, width: 56, height: 22)
            return f
        }
        func field(value: String, placeholder: String = "", y: CGFloat) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 60, y: y, width: 200, height: 22))
            f.stringValue = value
            f.placeholderString = placeholder
            return f
        }

        let pinLabel   = label("PIN：",  y: 82); container.addSubview(pinLabel)
        let pinField   = field(value: diskCfg.pin, placeholder: "留空则每次重启随机生成", y: 82)
        container.addSubview(pinField)

        let portLabel  = label("端口：", y: 46); container.addSubview(portLabel)
        let portField  = field(value: "\(diskCfg.port)", y: 46)
        container.addSubview(portField)

        let relayLabel = label("中继：", y: 10); container.addSubview(relayLabel)
        let relayField = field(value: diskCfg.relayUrl, placeholder: "ws://your-relay:7789（留空不用）", y: 10)
        container.addSubview(relayField)

        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newPin   = pinField.stringValue.trimmingCharacters(in: .whitespaces)
        let newPort  = UInt16(portField.stringValue) ?? diskCfg.port
        let newRelay = relayField.stringValue.trimmingCharacters(in: .whitespaces)

        diskCfg.pin      = newPin   // 空字符串 → 下次启动随机生成
        diskCfg.port     = newPort
        diskCfg.relayUrl = newRelay
        diskCfg.save()

        // Restart the agent to apply changes
        let exePath = ProcessInfo.processInfo.arguments[0]
        _ = try? Process.run(URL(fileURLWithPath: exePath), arguments: [])
        NSApp.terminate(nil)
    }

    // MARK: - Actions

    // InputLocker.onLockChanged (wired in main.swift) broadcasts the change
    // to connected clients and calls notifyStatus() itself — this just needs
    // to flip the lock; the menu item disappearing on the next refresh() is
    // handled by that same callback, not by anything here.
    @objc private func unlockInput() {
        InputLocker.shared.setLocked(false)
    }

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
        NSPasteboard.general.setString("wss://\(ip):7788", forType: .string)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func pickAndSendFile() {
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onSendFile?(url)
    }

    @objc private func copyWebURL(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://\(ip):7788", forType: .string)
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
