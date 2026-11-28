import AppKit

/// Native macOS Connect window — a single centered card mirroring the Web / Windows login page:
/// bee logo + "Remoter" + subtitle, direct/relay tabs, one address field (`wss://host:port`),
/// saved-account banner (machine name + model badge, account picker, 备注 / 忘记),
/// PIN / 账户密码 tabs, 记住登录状态, red error box, 连接 button and version.
public final class ConnectWindowController: NSWindowController, NSTextFieldDelegate {
    public var onConnectRequested: ((ConnectParams) -> Void)?

    private static let cardWidth: CGFloat = 420
    private static let padX: CGFloat = 34
    private static let outerX: CGFloat = 28
    private static let outerY: CGFloat = 24
    private static let otherAccountTitle = "+ 使用其他账户…"

    // State
    private var devices: [SavedDevice] = []
    private var selectedDevice: SavedDevice?
    private var isRelay = false
    private var isCredentials = false
    private var isEditingNote = false

    private let card = Theme.makeCard(background: Theme.surface, cornerRadius: 16)

    // Mode tabs
    private let directTab = Theme.makeButton(title: "🔌 直连 (局域网)", style: .primary, fontSize: 13)
    private let relayTab = Theme.makeButton(title: "🌐 中继 (公网)", style: .secondary, fontSize: 13)

    // Direct
    private let directContainer = NSStackView()
    private let addressField = Theme.makeTextField(placeholder: "wss://192.168.1.100:7788")
    private let lanSection = NSStackView()
    private let lanPillsStack = NSStackView()
    private var lanPeers: [DiscoveredLanPeer] = []
    private let lanBrowser = LanDiscoveryBrowser()

    // Saved-account banner
    private let savedBanner = ThemedLayerView()
    private let machineHeader = NSStackView()
    private let machineNameLabel = Theme.makeLabel("", size: 15, weight: .bold, color: Theme.textPrimary)
    private let modelBadge = Theme.makeBadge(text: "", background: Theme.surface, foreground: Theme.textMuted)
    private let bannerDivider = Theme.makeSeparator()
    private let accountRow = NSStackView()
    private let accountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let noteButton = Theme.makeButton(title: "备注", style: .toolbar, fontSize: 12)
    private let forgetButton = Theme.makeButton(title: "忘记", style: .toolbar, fontSize: 12)
    private let noteRow = NSStackView()
    private let noteField = Theme.makeTextField(placeholder: "输入备注名称…")
    private let noteDoneButton = Theme.makeButton(title: "完成", style: .toolbar, fontSize: 12)

    // Auth
    private let authTabsRow = NSStackView()
    private let pinTab = Theme.makeButton(title: "PIN 码", style: .toolbarActive, fontSize: 12)
    private let credentialsTab = Theme.makeButton(title: "账户密码", style: .toolbar, fontSize: 12)
    private let pinField = Theme.makeTextField(placeholder: "输入 6 位 PIN", secure: true)
    private let usernameField = Theme.makeTextField(placeholder: "Windows / macOS 账户名")
    private let passwordField = Theme.makeTextField(placeholder: "账户密码", secure: true)
    private var pinSection = NSStackView()
    private var credentialsSection = NSStackView()
    private let rememberCheckbox = Theme.makeCheckbox(title: "记住登录状态", checked: false)

    // Relay
    private let relayContainer = NSStackView()
    private let relayUrlField = Theme.makeTextField(placeholder: "wss://your-relay:7789")
    private let sessionIdField = Theme.makeTextField(placeholder: "A1B2C3")

    // Footer
    private let errorBox = ThemedLayerView()
    private let statusLabel = Theme.makeLabel("", size: 13, color: Theme.textMuted)
    private let connectButton = Theme.makeButton(title: "连接", style: .primary, fontSize: 15, weight: .semibold)

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth + Self.outerX * 2, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remoter v\(kAppVersion)"
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        buildUI()
        reloadDevices()
        if let latest = devices.max(by: { $0.lastConnectedAt < $1.lastConnectedAt }) {
            selectDevice(latest)
        }
        refreshAll()
        lanBrowser.onPeersChanged = { [weak self] peers in
            DispatchQueue.main.async { self?.updateLanPeers(peers) }
        }
        lanBrowser.start()
    }

    deinit {
        lanBrowser.stop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    public func reloadDevices() {
        devices = DeviceStore.shared.getDevices()
        if let selected = selectedDevice {
            selectedDevice = devices.first(where: { $0.id == selected.id })
        }
        refreshBanner()
        fitWindow()
    }

    public func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? Theme.danger : Theme.textMuted
        errorBox.isHidden = message.isEmpty
        errorBox.fillColor = isError ? Theme.dangerBackground : .clear
        errorBox.strokeColor = isError ? Theme.dangerBorder : .clear
        fitWindow()
    }

    public func showAndFocus(errorMessage: String? = nil) {
        reloadDevices()
        lanBrowser.start()
        if let errorMessage, !errorMessage.isEmpty {
            setStatus(errorMessage, isError: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Logo + title
        let logo = NSImageView()
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 36).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = Theme.makeLabel("Remoter", size: 28, weight: .bold, color: Theme.textPrimary)
        let logoRow = NSStackView(views: [logo, title])
        logoRow.orientation = .horizontal
        logoRow.spacing = 12
        logoRow.alignment = .centerY
        logoRow.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = Theme.makeLabel("远程控制 · 超清 2K · 60fps", size: 13, color: Theme.textMuted)

        // Mode tabs
        directTab.target = self
        directTab.action = #selector(modeTabClicked(_:))
        relayTab.target = self
        relayTab.action = #selector(modeTabClicked(_:))
        let modeRow = row([directTab, relayTab], spacing: 8, equal: true)
        directTab.heightAnchor.constraint(equalToConstant: 34).isActive = true
        relayTab.heightAnchor.constraint(equalToConstant: 34).isActive = true

        buildDirectContainer()
        buildRelayContainer()

        // Error / status box
        errorBox.cornerRadius = 6
        errorBox.strokeWidth = 1
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = Self.cardWidth - Self.padX * 2 - 24
        errorBox.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: errorBox.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: errorBox.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: -8),
        ])
        errorBox.isHidden = true

        connectButton.target = self
        connectButton.action = #selector(handleConnect)
        connectButton.keyEquivalent = "\r"
        connectButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let version = Theme.makeLabel("v\(kAppVersion)", size: 11, color: Theme.textMuted)
        version.alphaValue = 0.6
        version.alignment = .center

        let root = column(
            [logoRow, subtitle, modeRow, directContainer, relayContainer, errorBox, connectButton, version],
            spacing: 14
        )
        root.setCustomSpacing(4, after: logoRow)
        root.setCustomSpacing(12, after: subtitle)
        root.setCustomSpacing(8, after: connectButton)

        card.addSubview(root)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.padX),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.padX),
            root.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            card.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.outerY),
        ])

        for field in [addressField, pinField, usernameField, passwordField, relayUrlField, sessionIdField, noteField] {
            field.delegate = self
        }
    }

    private func buildDirectContainer() {
        // LAN quick-pick pills (hidden when nothing discovered)
        let lanLabel = Theme.makeLabel("局域网设备 (点击自动填入)", size: 11.5, weight: .medium, color: Theme.accent)
        lanPillsStack.orientation = .horizontal
        lanPillsStack.alignment = .centerY
        lanPillsStack.spacing = 6
        lanPillsStack.translatesAutoresizingMaskIntoConstraints = false
        lanSection.orientation = .vertical
        lanSection.alignment = .leading
        lanSection.spacing = 4
        lanSection.translatesAutoresizingMaskIntoConstraints = false
        lanSection.addArrangedSubview(lanLabel)
        lanSection.addArrangedSubview(lanPillsStack)
        lanSection.isHidden = true

        buildSavedBanner()

        authTabsRow.orientation = .horizontal
        authTabsRow.distribution = .fillEqually
        authTabsRow.spacing = 6
        authTabsRow.translatesAutoresizingMaskIntoConstraints = false
        for tab in [pinTab, credentialsTab] {
            tab.target = self
            tab.action = #selector(authTabClicked(_:))
            tab.heightAnchor.constraint(equalToConstant: 30).isActive = true
            authTabsRow.addArrangedSubview(tab)
        }

        pinSection = labeled("PIN 码", pinField)
        credentialsSection = column([labeled("用户名", usernameField), labeled("密码", passwordField)], spacing: 14)

        rememberCheckbox.font = Theme.font(size: 13)

        let stack = column(
            [labeled("被控端地址", addressField), lanSection, savedBanner, authTabsRow,
             pinSection, credentialsSection, rememberCheckbox],
            spacing: 14,
            into: directContainer
        )
        _ = stack
    }

    private func buildSavedBanner() {
        savedBanner.fillColor = Theme.elevated
        savedBanner.strokeColor = Theme.accent
        savedBanner.strokeWidth = 1
        savedBanner.cornerRadius = 10
        savedBanner.translatesAutoresizingMaskIntoConstraints = false

        machineHeader.orientation = .horizontal
        machineHeader.spacing = 8
        machineHeader.alignment = .centerY
        machineHeader.translatesAutoresizingMaskIntoConstraints = false
        machineNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        machineHeader.addArrangedSubview(machineNameLabel)
        machineHeader.addArrangedSubview(modelBadge)

        let icon = Theme.makeLabel("👤", size: 18)
        accountPopup.isBordered = false
        accountPopup.font = Theme.font(size: 13, weight: .semibold)
        accountPopup.target = self
        accountPopup.action = #selector(accountPopupChanged)
        accountPopup.translatesAutoresizingMaskIntoConstraints = false
        accountPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        noteButton.target = self
        noteButton.action = #selector(startEditNote)
        forgetButton.target = self
        forgetButton.action = #selector(forgetAccount)
        for b in [noteButton, forgetButton] {
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        accountRow.orientation = .horizontal
        accountRow.spacing = 8
        accountRow.alignment = .centerY
        accountRow.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, accountPopup, noteButton, forgetButton] { accountRow.addArrangedSubview(v) }

        noteDoneButton.target = self
        noteDoneButton.action = #selector(finishEditNote)
        noteDoneButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        noteDoneButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        noteField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        noteRow.orientation = .horizontal
        noteRow.spacing = 8
        noteRow.alignment = .centerY
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.addArrangedSubview(noteField)
        noteRow.addArrangedSubview(noteDoneButton)
        noteRow.isHidden = true

        let inner = NSStackView(views: [machineHeader, bannerDivider, accountRow, noteRow])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        inner.translatesAutoresizingMaskIntoConstraints = false
        savedBanner.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: savedBanner.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: savedBanner.trailingAnchor),
            inner.topAnchor.constraint(equalTo: savedBanner.topAnchor),
            inner.bottomAnchor.constraint(equalTo: savedBanner.bottomAnchor),
            machineHeader.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24),
            bannerDivider.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24),
            accountRow.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24),
            noteRow.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24),
        ])
        savedBanner.isHidden = true
    }

    private func buildRelayContainer() {
        sessionIdField.placeholderString = "A1B2C3"
        _ = column(
            [labeled("中继服务器地址", relayUrlField), labeled("会话 ID", sessionIdField)],
            spacing: 14,
            into: relayContainer
        )
    }

    // MARK: - Layout helpers

    /// Vertical stack whose children are all as wide as the stack itself.
    @discardableResult
    private func column(_ views: [NSView], spacing: CGFloat, into existing: NSStackView? = nil) -> NSStackView {
        let stack = existing ?? NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func row(_ views: [NSView], spacing: CGFloat, equal: Bool) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        if equal { stack.distribution = .fillEqually }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func labeled(_ text: String, _ field: NSView) -> NSStackView {
        let label = Theme.makeLabel(text, size: 13, color: Theme.textMuted)
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return column([label, field], spacing: 6)
    }

    /// Resize the window to the card's natural height, keeping the top edge where it is.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let contentSize = NSSize(width: Self.cardWidth + Self.outerX * 2,
                                 height: card.fittingSize.height + Self.outerY * 2)
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - State refresh

    private func refreshAll() {
        directTab.buttonStyle = isRelay ? .secondary : .primary
        relayTab.buttonStyle = isRelay ? .primary : .secondary
        pinTab.buttonStyle = isCredentials ? .toolbar : .toolbarActive
        credentialsTab.buttonStyle = isCredentials ? .toolbarActive : .toolbar
        directContainer.isHidden = isRelay
        relayContainer.isHidden = !isRelay
        pinSection.isHidden = isCredentials
        credentialsSection.isHidden = !isCredentials
        refreshBanner()
        fitWindow()
    }

    private func refreshBanner() {
        savedBanner.isHidden = devices.isEmpty
        rememberCheckbox.isHidden = usesStoredToken

        accountPopup.removeAllItems()
        for d in devices {
            accountPopup.addItem(withTitle: "\(d.displayName) (\(d.host))")
        }
        accountPopup.addItem(withTitle: Self.otherAccountTitle)
        if let selected = selectedDevice, let idx = devices.firstIndex(where: { $0.id == selected.id }) {
            accountPopup.selectItem(at: idx)
        } else {
            accountPopup.selectItem(at: devices.count)
        }

        let hasSelection = selectedDevice != nil
        for b in [noteButton, forgetButton] { b.isEnabled = hasSelection }

        let comp = selectedDevice?.computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = selectedDevice?.modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showInfo = hasSelection && (!comp.isEmpty || !model.isEmpty)
        machineNameLabel.stringValue = comp
        modelBadge.text = model
        modelBadge.isHidden = model.isEmpty
        machineHeader.isHidden = !showInfo
        bannerDivider.isHidden = !showInfo

        accountRow.isHidden = isEditingNote
        noteRow.isHidden = !isEditingNote
    }

    /// A saved device with a stored token connects without typing a password (web "token" auth).
    private var usesStoredToken: Bool {
        guard isCredentials, let token = selectedDevice?.token, !token.isEmpty else { return false }
        return passwordField.stringValue.isEmpty
    }

    // MARK: - Address helpers

    private func formatAddress(_ device: SavedDevice) -> String {
        "\(device.useTls ? "wss" : "ws")://\(device.host):\(device.port)"
    }

    /// Accepts `wss://host:port`, `ws://host:port`, `https://…`, `http://…` or a bare `host[:port]` (→ wss, 7788).
    private func parseAddress(_ raw: String) -> (host: String, port: Int, tls: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var tls = true
        if let r = s.range(of: "://") {
            switch s[..<r.lowerBound].lowercased() {
            case "wss", "https": tls = true
            case "ws", "http": tls = false
            default: return nil
            }
            s = String(s[r.upperBound...])
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        var host = s
        var port = 7788
        if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon])
            guard let p = Int(s[s.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
        }
        guard !host.isEmpty else { return nil }
        return (host, port, tls)
    }

    // MARK: - Selecting / editing saved devices

    private func selectDevice(_ device: SavedDevice) {
        selectedDevice = device
        isEditingNote = false
        addressField.stringValue = formatAddress(device)
        if device.authMode == .credentials || device.authMode == .token {
            isCredentials = true
            usernameField.stringValue = device.username ?? ""
            passwordField.stringValue = ""
            pinField.stringValue = ""
        } else {
            isCredentials = false
            pinField.stringValue = device.pin ?? ""
        }
    }

    @objc private func accountPopupChanged() {
        let idx = accountPopup.indexOfSelectedItem
        setStatus("")
        if idx >= 0, idx < devices.count {
            selectDevice(devices[idx])
        } else {
            selectedDevice = nil
            isEditingNote = false
            isCredentials = false
            pinField.stringValue = ""
            passwordField.stringValue = ""
        }
        refreshAll()
    }

    @objc private func startEditNote() {
        guard let device = selectedDevice else { return }
        noteField.stringValue = device.name
        isEditingNote = true
        refreshBanner()
        fitWindow()
        window?.makeFirstResponder(noteField)
    }

    @objc private func finishEditNote() {
        guard isEditingNote else { return }
        isEditingNote = false
        if var device = selectedDevice {
            let name = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                device.name = name
                DeviceStore.shared.upsertDevice(device)
                selectedDevice = device
            }
        }
        reloadDevices()
    }

    @objc private func forgetAccount() {
        guard let device = selectedDevice else { return }
        DeviceStore.shared.removeDevice(id: device.id)
        selectedDevice = nil
        isCredentials = false
        pinField.stringValue = ""
        passwordField.stringValue = ""
        reloadDevices()
        refreshAll()
        setStatus("已忘记 \(device.displayName)")
    }

    // MARK: - LAN discovery

    private func updateLanPeers(_ peers: [DiscoveredLanPeer]) {
        lanPeers = peers
        for view in lanPillsStack.arrangedSubviews {
            lanPillsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        lanSection.isHidden = peers.isEmpty
        for (idx, peer) in peers.prefix(4).enumerated() {
            let btn = Theme.makeButton(title: "📡 \(peer.name)", style: .toolbar, fontSize: 11.5, weight: .medium)
            btn.tag = idx
            btn.target = self
            btn.action = #selector(lanPeerPillClicked(_:))
            btn.toolTip = "\(peer.name) — \(peer.host):\(peer.wsPort)"
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
            lanPillsStack.addArrangedSubview(btn)
        }
        fitWindow()
    }

    @objc private func lanPeerPillClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < lanPeers.count else { return }
        let peer = lanPeers[sender.tag]
        isRelay = false
        selectedDevice = nil
        addressField.stringValue = "wss://\(peer.host):\(peer.wsPort)"
        refreshAll()
        setStatus("已填入局域网设备: \(peer.name) (\(peer.host):\(peer.wsPort))")
        window?.makeFirstResponder(isCredentials ? passwordField : pinField)
    }

    // MARK: - Tabs

    @objc private func modeTabClicked(_ sender: NSButton) {
        isRelay = (sender === relayTab)
        setStatus("")
        refreshAll()
    }

    @objc private func authTabClicked(_ sender: NSButton) {
        isCredentials = (sender === credentialsTab)
        // Picking a tab by hand means "not the stored-token login of the selected account".
        if !isCredentials { selectedDevice = nil }
        setStatus("")
        refreshAll()
    }

    // MARK: - Connect

    @objc private func handleConnect() {
        setStatus("")

        if isRelay {
            let relayUrl = relayUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionId = sessionIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relayUrl.isEmpty else {
                setStatus("请输入中继服务器地址（如 wss://host:7789）", isError: true)
                return
            }
            guard !sessionId.isEmpty else {
                setStatus("请输入会话 ID", isError: true)
                return
            }
            let params = ConnectParams(
                mode: .relay,
                relayUrl: relayUrl,
                sessionId: sessionId,
                pin: "",
                label: "Relay \(sessionId)",
                authMode: .pin,
                rememberDevice: false
            )
            do {
                _ = try params.buildWebSocketURL()
            } catch {
                setStatus(error.localizedDescription, isError: true)
                return
            }
            onConnectRequested?(params)
            return
        }

        guard let addr = parseAddress(addressField.stringValue) else {
            setStatus("请输入有效的被控端地址，例如 wss://192.168.1.144:7788", isError: true)
            return
        }
        let host = addr.host
        let port = addr.port
        let useTls = addr.tls

        let secret = isCredentials ? passwordField.stringValue : pinField.stringValue
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = DeviceStore.shared.findByHost(host, port: port)

        var authMode: AuthMode = isCredentials ? .credentials : .pin
        var savedToken: String? = nil
        if isCredentials {
            guard !username.isEmpty else {
                setStatus("请输入用户名", isError: true)
                return
            }
            if secret.isEmpty, let token = stored?.token, !token.isEmpty {
                authMode = .token
                savedToken = token
            } else if secret.isEmpty {
                setStatus("请输入密码", isError: true)
                return
            }
        }
        // Token login always keeps the device (web: rememberDevice = true for saved accounts).
        let remember = (authMode == .token) || rememberCheckbox.state == .on

        let params = ConnectParams(
            mode: .direct,
            host: host,
            port: port,
            useTls: useTls,
            pin: isCredentials ? "" : secret,
            label: selectedDevice?.displayName ?? "\(host):\(port)",
            authMode: authMode,
            username: isCredentials ? username : nil,
            password: isCredentials ? secret : nil,
            token: savedToken,
            rememberDevice: remember
        )
        do {
            _ = try params.buildWebSocketURL()
        } catch {
            setStatus(error.localizedDescription, isError: true)
            return
        }

        if remember {
            let device = SavedDevice(
                id: selectedDevice?.id ?? stored?.id ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                name: selectedDevice?.name ?? "",
                host: host,
                port: port,
                useTls: useTls,
                authMode: isCredentials ? .credentials : .pin,
                pin: isCredentials ? nil : secret,
                username: isCredentials ? username : nil,
                token: savedToken,
                computerName: selectedDevice?.computerName,
                modelId: selectedDevice?.modelId,
                serverOs: selectedDevice?.serverOs,
                lastConnectedAt: Date()
            )
            DeviceStore.shared.upsertDevice(device)
            reloadDevices()
        }

        onConnectRequested?(params)
    }

    // MARK: - NSTextFieldDelegate

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === noteField {
            finishEditNote()
        } else {
            handleConnect()
        }
        return true
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === sessionIdField {
            let upper = String(field.stringValue.uppercased().prefix(6))
            if upper != field.stringValue { field.stringValue = upper }
        } else if field === passwordField {
            rememberCheckbox.isHidden = usesStoredToken
            fitWindow()
        }
    }
}
