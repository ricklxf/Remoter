import AppKit

/// Pure AppKit application delegate managing the Connect window, active Desktop session,
/// standard macOS menu bar, and Dock reopen behavior.
final class RemoterAppDelegate: NSObject, NSApplicationDelegate {
    private var connectWindowController: ConnectWindowController?
    private var desktopWindowController: DesktopWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        showConnectWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let desktop = desktopWindowController, let win = desktop.window {
                win.makeKeyAndOrderFront(nil)
            } else {
                showConnectWindow()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopWindowController?.disconnectAndClose(errorMessage: nil)
    }

    // MARK: - Window Coordination

    private func showConnectWindow(errorMessage: String? = nil) {
        if connectWindowController == nil {
            let controller = ConnectWindowController()
            controller.onConnectRequested = { [weak self] params in
                self?.openDesktopSession(with: params)
            }
            connectWindowController = controller
        }
        connectWindowController?.showAndFocus(errorMessage: errorMessage)
    }

    private func openDesktopSession(with params: ConnectParams) {
        desktopWindowController?.disconnectAndClose(errorMessage: nil)

        let desktop = DesktopWindowController(params: params)
        desktop.onClosed = { [weak self] errorMessage in
            guard let self else { return }
            self.desktopWindowController = nil
            self.showConnectWindow(errorMessage: errorMessage)
        }
        desktopWindowController = desktop

        connectWindowController?.window?.orderOut(nil)
        desktop.startSession()
    }

    // MARK: - Standard macOS Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu ("Remoter")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Remoter")
        appMenu.addItem(withTitle: "关于 Remoter Client", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Remoter Client", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Remoter Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cmd+C/V/X/A in text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu (Ctrl+Cmd+F fullscreen)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        let fullScreenItem = viewMenu.addItem(withTitle: "进入/退出全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu (Cmd+W close, Cmd+M minimize)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = kAppDisplayName
        alert.informativeText = "版本 v\(kAppVersion)\n原生 macOS Metal + VideoToolbox 远程桌面客户端"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = RemoterAppDelegate()
app.delegate = delegate
app.run()
