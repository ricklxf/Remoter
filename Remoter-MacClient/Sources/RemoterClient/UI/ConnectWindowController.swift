import AppKit

/// Native dark macOS Connect window (`780x540`).
/// Left pane: Saved Devices (`DeviceStore.shared`) with OS icon, double-click quick connect, and delete.
/// Right pane: Direct vs Relay mode switch, Direct (Host/Port/TLS/PIN or Credentials/Remember) & Relay fields, Connect button, status/error label.
public final class ConnectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public var onConnectRequested: ((ConnectParams) -> Void)?

    // Saved devices state
    private var devices: [SavedDevice] = []
    private let devicesTableView = NSTableView()
    private let emptyDevicesLabel = Theme.makeLabel("暂无已保存设备", size: 12.5, color: Theme.textMuted)
    private let quickConnectButton = Theme.makeButton(title: "快速连接", style: .secondary, fontSize: 12)
    private let deleteDeviceButton = Theme.makeButton(title: "删除", style: .danger, fontSize: 12)

    // Mode switch
    private let modeSegmented = NSSegmentedControl(labels: ["直连 (Direct)", "中继 (Relay)"], trackingMode: .selectOne, target: nil, action: nil)

    // Direct mode fields
    private let directContainer = NSView()
    private let hostField = Theme.makeTextField(placeholder: "192.168.1.100 或主机名")
    private let portField = Theme.makeTextField(placeholder: "7788", text: "7788")
    private let tlsCheckbox = Theme.makeCheckbox(title: "启用 TLS 加密 (wss://)", checked: true)
    private let authSegmented = NSSegmentedControl(labels: ["PIN 码", "账号密码"], trackingMode: .selectOne, target: nil, action: nil)
    private let usernameLabel = Theme.makeLabel("用户名", size: 12, weight: .medium, color: Theme.textMuted)
    private let usernameField = Theme.makeTextField(placeholder: "系统用户名")
    private let secretLabel = Theme.makeLabel("PIN 码", size: 12, weight: .medium, color: Theme.textMuted)
    private let secretField = Theme.makeTextField(placeholder: "输入访问 PIN 码", secure: true)
    private let rememberCheckbox = Theme.makeCheckbox(title: "记住此设备（保存至本地列表）", checked: true)

    // Relay mode fields
    private let relayContainer = NSView()
    private let relayUrlField = Theme.makeTextField(placeholder: "ws://relay.example.com:7789", text: "ws://127.0.0.1:7789")
    private let sessionIdField = Theme.makeTextField(placeholder: "输入会话 ID")
    private let relayPinField = Theme.makeTextField(placeholder: "输入 PIN 码", secure: true)

    // Action & status
    private let connectButton = Theme.makeButton(title: "连  接", style: .primary, fontSize: 14, weight: .semibold)
    private let statusLabel = Theme.makeLabel("", size: 12, color: Theme.textMuted)

    private var selectedDevice: SavedDevice?

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remoter Client v\(kAppVersion)"
        window.appearance = Theme.darkAppearance
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        buildUI()
        reloadDevices()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    public func reloadDevices() {
        devices = DeviceStore.shared.getDevices()
        devicesTableView.reloadData()
        emptyDevicesLabel.isHidden = !devices.isEmpty
        if let selected = selectedDevice, let idx = devices.firstIndex(where: { $0.id == selected.id }) {
            devicesTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            selectedDevice = nil
            updateDeviceActionButtons()
        }
    }

    public func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? Theme.danger : Theme.textMuted
    }

    public func showAndFocus(errorMessage: String? = nil) {
        reloadDevices()
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
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Theme.background.cgColor

        let leftCard = buildLeftPane()
        let rightCard = buildRightPane()

        contentView.addSubview(leftCard)
        contentView.addSubview(rightCard)

        NSLayoutConstraint.activate([
            leftCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            leftCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            leftCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            leftCard.widthAnchor.constraint(equalToConstant: 290),

            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 16),
            rightCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rightCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rightCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        updateModeVisibility()
        updateAuthVisibility()
        updateDeviceActionButtons()
    }

    private func buildLeftPane() -> NSView {
        let card = Theme.makeCard(background: Theme.surface, cornerRadius: 12)

        let headerTitle = Theme.makeLabel("已保存设备", size: 15, weight: .semibold, color: Theme.textPrimary)
        let headerSub = Theme.makeLabel("双击设备快速连接", size: 11.5, color: Theme.textMuted)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DeviceColumn"))
        column.resizingMask = .autoresizingMask
        devicesTableView.addTableColumn(column)
        devicesTableView.headerView = nil
        devicesTableView.backgroundColor = .clear
        devicesTableView.rowHeight = 56
        devicesTableView.intercellSpacing = NSSize(width: 0, height: 4)
        devicesTableView.selectionHighlightStyle = .regular
        devicesTableView.dataSource = self
        devicesTableView.delegate = self
        devicesTableView.target = self
        devicesTableView.doubleAction = #selector(handleDeviceDoubleClick)

        let scrollView = NSScrollView()
        scrollView.documentView = devicesTableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyDevicesLabel.alignment = .center

        quickConnectButton.target = self
        quickConnectButton.action = #selector(handleQuickConnect)
        deleteDeviceButton.target = self
        deleteDeviceButton.action = #selector(handleDeleteDevice)

        let footerStack = NSStackView(views: [quickConnectButton, deleteDeviceButton])
        footerStack.orientation = .horizontal
        footerStack.spacing = 8
        footerStack.distribution = .fill
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let sep = Theme.makeSeparator(vertical: false)

        card.addSubview(headerTitle)
        card.addSubview(headerSub)
        card.addSubview(sep)
        card.addSubview(scrollView)
        card.addSubview(emptyDevicesLabel)
        card.addSubview(footerStack)

        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            headerTitle.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            headerTitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            headerSub.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            headerSub.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 2),
            headerSub.trailingAnchor.constraint(equalTo: headerTitle.trailingAnchor),

            sep.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: headerSub.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -10),

            emptyDevicesLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyDevicesLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            quickConnectButton.heightAnchor.constraint(equalToConstant: 30),
            deleteDeviceButton.heightAnchor.constraint(equalToConstant: 30),
            deleteDeviceButton.widthAnchor.constraint(equalToConstant: 68),
        ])

        return card
    }

    private func buildRightPane() -> NSView {
        let card = Theme.makeCard(background: Theme.surface, cornerRadius: 12)

        let titleLabel = Theme.makeLabel("Remoter", size: 22, weight: .bold, color: Theme.textPrimary)
        let subtitleLabel = Theme.makeLabel("Native Metal & VideoToolbox Remote Desktop", size: 12, weight: .medium, color: Theme.accent)
        let versionBadge = Theme.makeBadge(text: "v\(kAppVersion)", background: Theme.elevated, foreground: Theme.textMuted)

        modeSegmented.selectedSegment = 0
        modeSegmented.segmentStyle = .rounded
        modeSegmented.target = self
        modeSegmented.action = #selector(modeChanged)
        modeSegmented.translatesAutoresizingMaskIntoConstraints = false

        buildDirectContainer()
        buildRelayContainer()

        connectButton.target = self
        connectButton.action = #selector(handleConnect)

        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping

        card.addSubview(titleLabel)
        card.addSubview(versionBadge)
        card.addSubview(subtitleLabel)
        card.addSubview(modeSegmented)
        card.addSubview(directContainer)
        card.addSubview(relayContainer)
        card.addSubview(connectButton)
        card.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            versionBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            versionBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            modeSegmented.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            modeSegmented.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            modeSegmented.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),

            directContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            directContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            directContainer.topAnchor.constraint(equalTo: modeSegmented.bottomAnchor, constant: 16),
            directContainer.bottomAnchor.constraint(equalTo: connectButton.topAnchor, constant: -14),

            relayContainer.leadingAnchor.constraint(equalTo: directContainer.leadingAnchor),
            relayContainer.trailingAnchor.constraint(equalTo: directContainer.trailingAnchor),
            relayContainer.topAnchor.constraint(equalTo: directContainer.topAnchor),
            relayContainer.bottomAnchor.constraint(equalTo: directContainer.bottomAnchor),

            connectButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            connectButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            connectButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            connectButton.heightAnchor.constraint(equalToConstant: 40),

            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        for field in [hostField, portField, usernameField, secretField, relayUrlField, sessionIdField, relayPinField] {
            field.delegate = self
        }

        return card
    }

    private func buildDirectContainer() {
        directContainer.translatesAutoresizingMaskIntoConstraints = false

        let hostLabel = Theme.makeLabel("主机 / IP 地址", size: 12, weight: .medium, color: Theme.textMuted)
        let portLabel = Theme.makeLabel("端口", size: 12, weight: .medium, color: Theme.textMuted)
        let authLabel = Theme.makeLabel("认证方式", size: 12, weight: .medium, color: Theme.textMuted)

        authSegmented.selectedSegment = 0
        authSegmented.segmentStyle = .rounded
        authSegmented.target = self
        authSegmented.action = #selector(authModeChanged)
        authSegmented.translatesAutoresizingMaskIntoConstraints = false

        let hostCol = makeVerticalField(label: hostLabel, field: hostField)
        let portCol = makeVerticalField(label: portLabel, field: portField)
        portCol.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let hostPortRow = NSStackView(views: [hostCol, portCol])
        hostPortRow.orientation = .horizontal
        hostPortRow.spacing = 10
        hostPortRow.alignment = .top
        hostPortRow.translatesAutoresizingMaskIntoConstraints = false

        let authRow = NSStackView(views: [authSegmented, tlsCheckbox])
        authRow.orientation = .horizontal
        authRow.spacing = 14
        authRow.alignment = .centerY
        authRow.translatesAutoresizingMaskIntoConstraints = false

        let authSection = NSStackView(views: [authLabel, authRow])
        authSection.orientation = .vertical
        authSection.alignment = .leading
        authSection.spacing = 5
        authSection.translatesAutoresizingMaskIntoConstraints = false

        let userSection = makeVerticalField(label: usernameLabel, field: usernameField)
        let secretSection = makeVerticalField(label: secretLabel, field: secretField)

        let mainStack = NSStackView(views: [hostPortRow, authSection, userSection, secretSection, rememberCheckbox])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        directContainer.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: directContainer.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: directContainer.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: directContainer.topAnchor),

            hostPortRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            userSection.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            secretSection.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
        ])
    }

    private func buildRelayContainer() {
        relayContainer.translatesAutoresizingMaskIntoConstraints = false

        let relayUrlLabel = Theme.makeLabel("中继服务器地址 (Relay URL)", size: 12, weight: .medium, color: Theme.textMuted)
        let sessionLabel = Theme.makeLabel("会话 ID (Session ID)", size: 12, weight: .medium, color: Theme.textMuted)
        let pinLabel = Theme.makeLabel("PIN 码", size: 12, weight: .medium, color: Theme.textMuted)

        let urlSection = makeVerticalField(label: relayUrlLabel, field: relayUrlField)
        let sidSection = makeVerticalField(label: sessionLabel, field: sessionIdField)
        let pinSection = makeVerticalField(label: pinLabel, field: relayPinField)

        let stack = NSStackView(views: [urlSection, sidSection, pinSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        relayContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: relayContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: relayContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: relayContainer.topAnchor),

            urlSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sidSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pinSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeVerticalField(label: NSTextField, field: NSTextField) -> NSStackView {
        field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: - Actions & State

    @objc private func modeChanged() {
        updateModeVisibility()
        setStatus("")
    }

    @objc private func authModeChanged() {
        updateAuthVisibility()
        setStatus("")
    }

    private func updateModeVisibility() {
        let isRelay = modeSegmented.selectedSegment == 1
        directContainer.isHidden = isRelay
        relayContainer.isHidden = !isRelay
    }

    private func updateAuthVisibility() {
        let isCredentials = authSegmented.selectedSegment == 1
        usernameLabel.superview?.isHidden = !isCredentials
        secretLabel.stringValue = isCredentials ? "密码" : "PIN 码"
        secretField.placeholderString = isCredentials ? "输入系统登录密码" : "输入访问 PIN 码"
    }

    private func updateDeviceActionButtons() {
        let hasSelection = selectedDevice != nil
        quickConnectButton.isEnabled = hasSelection
        deleteDeviceButton.isEnabled = hasSelection
    }

    @objc private func handleConnect() {
        setStatus("")
        let isRelay = modeSegmented.selectedSegment == 1

        if isRelay {
            let relayUrl = relayUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionId = sessionIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let pin = relayPinField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !relayUrl.isEmpty else {
                setStatus("请输入中继服务器地址（如 ws://host:7789）", isError: true)
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
                pin: pin,
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
        } else {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                setStatus("请输入目标主机 IP 或域名", isError: true)
                return
            }

            let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(portText) ?? 7788
            guard (1...65535).contains(port) else {
                setStatus("端口号必须在 1 - 65535 之间", isError: true)
                return
            }

            let useTls = tlsCheckbox.state == .on
            let isCredentials = authSegmented.selectedSegment == 1
            let secret = secretField.stringValue
            let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let remember = rememberCheckbox.state == .on

            var authMode: AuthMode = isCredentials ? .credentials : .pin
            var savedToken: String? = nil

            if isCredentials {
                guard !username.isEmpty else {
                    setStatus("请输入用户名", isError: true)
                    return
                }
                if secret.isEmpty,
                   let existing = DeviceStore.shared.findByHost(host, port: port),
                   let token = existing.token, !token.isEmpty {
                    authMode = .token
                    savedToken = token
                } else if secret.isEmpty {
                    setStatus("请输入密码", isError: true)
                    return
                }
            }

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
                    id: selectedDevice?.id ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
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
    }

    @objc private func handleQuickConnect() {
        guard let device = selectedDevice else { return }
        populateForm(from: device)
        handleConnect()
    }

    @objc private func handleDeviceDoubleClick() {
        let row = devicesTableView.clickedRow
        guard row >= 0, row < devices.count else { return }
        selectedDevice = devices[row]
        updateDeviceActionButtons()
        populateForm(from: devices[row])
        handleConnect()
    }

    @objc private func handleDeleteDevice() {
        guard let device = selectedDevice else { return }
        DeviceStore.shared.removeDevice(id: device.id)
        selectedDevice = nil
        reloadDevices()
        setStatus("已删除设备 \(device.displayName)")
    }

    private func populateForm(from device: SavedDevice) {
        modeSegmented.selectedSegment = 0
        updateModeVisibility()

        hostField.stringValue = device.host
        portField.stringValue = "\(device.port)"
        tlsCheckbox.state = device.useTls ? .on : .off

        if device.authMode == .credentials || device.authMode == .token {
            authSegmented.selectedSegment = 1
            usernameField.stringValue = device.username ?? ""
            secretField.stringValue = ""
        } else {
            authSegmented.selectedSegment = 0
            secretField.stringValue = device.pin ?? ""
        }
        updateAuthVisibility()
        rememberCheckbox.state = .on
    }

    // MARK: - NSTextFieldDelegate (Enter to connect)

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            handleConnect()
            return true
        }
        return false
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        devices.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < devices.count else { return nil }
        let device = devices[row]
        let cellId = NSUserInterfaceItemIdentifier("SavedDeviceCell")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? SavedDeviceCellView)
            ?? SavedDeviceCellView(identifier: cellId)
        cell.configure(with: device)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = devicesTableView.selectedRow
        if row >= 0, row < devices.count {
            selectedDevice = devices[row]
            populateForm(from: devices[row])
        } else {
            selectedDevice = nil
        }
        updateDeviceActionButtons()
    }
}

// MARK: - SavedDeviceCellView

private final class SavedDeviceCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = Theme.makeLabel("", size: 13, weight: .semibold, color: Theme.textPrimary)
    private let addrLabel = Theme.makeLabel("", size: 11.5, color: Theme.textMuted, monospaced: true)
    private let tlsBadge = Theme.makeBadge(text: "TLS", background: Theme.accentDim, foreground: Theme.accent)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(addrLabel)
        addSubview(tlsBadge)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: tlsBadge.leadingAnchor, constant: -6),

            tlsBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            tlsBadge.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            addrLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            addrLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            addrLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with device: SavedDevice) {
        let symbol = Theme.osSymbolName(for: device.serverOs)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: device.serverOs)
        nameLabel.stringValue = device.displayName
        addrLabel.stringValue = "\(device.host):\(device.port)"
        tlsBadge.isHidden = !device.useTls
    }
}
