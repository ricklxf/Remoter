import AppKit

// MARK: - Status model

struct AgentStatus {
    var pin: String
    var sessionId: String?
    var localIPs: [String]
    var connectedClients: Int
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
            btn.title    = "⬡"
            btn.toolTip  = "Remoter"
            btn.font     = .monospacedSystemFont(ofSize: 14, weight: .regular)
        }
        refresh()
    }

    // MARK: - Menu build

    private func refresh() {
        let isConnected = status.connectedClients > 0

        // 图标：连接中显示实心点
        statusItem?.button?.title = isConnected ? "⬡•" : "⬡"

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

    @objc private func copyIP(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ws://\(ip):7788", forType: .string)
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
