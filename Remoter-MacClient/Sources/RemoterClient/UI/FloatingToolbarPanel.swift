import AppKit

/// Borderless child `NSPanel` pinned to the top-center of `DesktopWindowController`.
/// Collapses to a compact translucent pill (`▼  FPS · Mbps · RTT ms`), expands on click/hover,
/// and auto-collapses after 3 seconds of mouse-exit inactivity.
public final class FloatingToolbarPanel: NSPanel {
    private static let pillHeight: CGFloat = 24
    private static let barHeight: CGFloat = 42
    private static let autoCollapseDelay: TimeInterval = 3.0

    // MARK: - Callbacks
    public var onResolutionChanged: ((ResolutionTier) -> Void)?
    public var onScaleModeChanged: ((ScaleMode) -> Void)?
    public var onFpsChanged: ((Int, Bool) -> Void)?
    public var onBitrateChanged: ((Int, Bool) -> Void)?
    public var onCodecChanged: ((VideoCodec) -> Void)?
    public var onForceKeyframe: (() -> Void)?
    public var onCtrlAltDel: (() -> Void)?
    public var onLockScreen: (() -> Void)?
    public var onDisplaySelected: ((UInt32) -> Void)?
    public var onAudioToggled: ((Bool) -> Void)?
    public var onVolumeChanged: ((Float) -> Void)?
    public var onPrivacyToggled: ((Bool) -> Void)?
    public var onPointerLockToggled: (() -> Void)?
    public var onMacWinSwapToggled: ((Bool) -> Void)?
    public var onClipboardSyncToggled: ((Bool) -> Void)?
    public var onFileTransferRequested: (() -> Void)?
    public var onFullscreenToggled: (() -> Void)?
    public var onDisconnectRequested: (() -> Void)?

    // MARK: - State
    private weak var ownerWindow: NSWindow?
    private var isExpanded = false
    private var isMenuOpen = false
    private var autoHideTimer: Timer?

    private var resolution: ResolutionTier = .native
    private var scaleMode: ScaleMode = .fit
    private var fps: Int = 60
    private var fpsAuto: Bool = true
    private var bitrateBps: Int = 8_000_000
    private var bitrateAuto: Bool = true
    private var codec: VideoCodec = .h264
    private var audioOn: Bool = true
    private var volume: Float = 1.0
    private var privacyOn: Bool = false
    private var pointerLocked: Bool = false
    private var macWinSwapOn: Bool = true
    private var clipboardSyncOn: Bool = true
    private var isFullscreen: Bool = false
    private var isWindowsHost: Bool = false
    private var displays: [DisplayInfo] = []
    private var activeDisplayId: UInt32 = 0

    // MARK: - Views
    private let rootContainer = HoverTrackingView()
    private let visualEffect = NSVisualEffectView()

    // Collapsed pill
    private let pillButton = Theme.makeButton(title: "▼  0 fps · 0.0 Mbps · -- ms", style: .toolbar, fontSize: 11, weight: .medium)

    // Expanded bar
    private let barStack = NSStackView()
    private let hudLabel = Theme.makeLabel("0 fps · 0.0 Mbps · -- ms", size: 11.5, weight: .medium, color: Theme.textPrimary, monospaced: true)
    private let codecBadge = Theme.makeBadge(text: "H.264", background: Theme.infoDim, foreground: Theme.info)
    private let hwBadge = Theme.makeBadge(text: "HW", background: Theme.accentDim, foreground: Theme.accent)

    private let displayButton = Theme.makeButton(title: "显示器 ▾", style: .toolbar, fontSize: 11.5)
    private let qualityButton = Theme.makeButton(title: "画质 ▾", style: .toolbar, fontSize: 11.5)
    private let audioButton = Theme.makeButton(title: "声音: 开", style: .toolbarActive, fontSize: 11.5)
    private let volumeSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let privacyButton = Theme.makeButton(title: "隐私屏", style: .toolbar, fontSize: 11.5)
    private let pointerLockButton = Theme.makeButton(title: "游戏鼠标", style: .toolbar, fontSize: 11.5)
    private let keySwapButton = Theme.makeButton(title: "⌘↔Ctrl", style: .toolbarActive, fontSize: 11.5)
    private let clipboardButton = Theme.makeButton(title: "剪贴板", style: .toolbarActive, fontSize: 11.5)
    private let filesButton = Theme.makeButton(title: "文件", style: .toolbar, fontSize: 11.5)
    private let fullscreenButton = Theme.makeButton(title: "全屏", style: .toolbar, fontSize: 11.5)
    private let disconnectButton = Theme.makeButton(title: "断开", style: .danger, fontSize: 11.5, weight: .semibold)
    private let collapseButton = Theme.makeButton(title: "▲", style: .ghost, fontSize: 11)

    private let qualityMenu = NSMenu()
    private let displayMenu = NSMenu()

    public init(ownerWindow: NSWindow) {
        self.ownerWindow = ownerWindow
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: Self.pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        appearance = Theme.darkAppearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildUI()
        setExpanded(false)
    }

    deinit {
        autoHideTimer?.invalidate()
    }

    // MARK: - UI Setup

    private func buildUI() {
        rootContainer.wantsLayer = true
        rootContainer.layer?.cornerRadius = 10
        rootContainer.layer?.borderColor = Theme.border.cgColor
        rootContainer.layer?.borderWidth = 1
        rootContainer.layer?.masksToBounds = true
        rootContainer.onMouseEntered = { [weak self] in
            guard let self else { return }
            self.cancelAutoHide()
            if !self.isExpanded {
                self.setExpanded(true)
            }
        }
        rootContainer.onMouseExited = { [weak self] in
            guard let self else { return }
            if self.isExpanded && !self.isMenuOpen {
                self.scheduleAutoHide()
            }
        }
        contentView = rootContainer

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = Theme.darkAppearance
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        let tintOverlay = NSView()
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = Theme.hudBackground.cgColor
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false

        rootContainer.addSubview(visualEffect)
        rootContainer.addSubview(tintOverlay)

        // Pill button
        pillButton.target = self
        pillButton.action = #selector(expandTapped)
        rootContainer.addSubview(pillButton)

        // Volume slider
        volumeSlider.controlSize = .mini
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 58).isActive = true

        // Wire button actions
        displayButton.target = self
        displayButton.action = #selector(showDisplayMenu)
        displayButton.isHidden = true

        qualityButton.target = self
        qualityButton.action = #selector(showQualityMenu)

        audioButton.target = self
        audioButton.action = #selector(audioTapped)

        privacyButton.target = self
        privacyButton.action = #selector(privacyTapped)

        pointerLockButton.target = self
        pointerLockButton.action = #selector(pointerLockTapped)
        pointerLockButton.toolTip = "游戏鼠标 / 指针锁定 (⌃⌥↩)"

        keySwapButton.target = self
        keySwapButton.action = #selector(keySwapTapped)
        keySwapButton.toolTip = "Mac ⌘ ↔ Windows Ctrl 键位互换"
        keySwapButton.isHidden = true

        clipboardButton.target = self
        clipboardButton.action = #selector(clipboardTapped)

        filesButton.target = self
        filesButton.action = #selector(filesTapped)

        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreenTapped)

        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)

        collapseButton.target = self
        collapseButton.action = #selector(collapseTapped)

        // Bar stack
        let sep1 = Theme.makeSeparator(vertical: true)
        let sep2 = Theme.makeSeparator(vertical: true)
        sep1.heightAnchor.constraint(equalToConstant: 18).isActive = true
        sep2.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let controls: [NSView] = [
            hudLabel, codecBadge, hwBadge, sep1,
            displayButton, qualityButton,
            audioButton, volumeSlider,
            privacyButton, pointerLockButton, keySwapButton, clipboardButton, filesButton,
            sep2, fullscreenButton, disconnectButton, collapseButton
        ]
        for view in controls {
            barStack.addArrangedSubview(view)
        }
        barStack.orientation = .horizontal
        barStack.alignment = .centerY
        barStack.spacing = 6
        barStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        barStack.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(barStack)

        for btn in [displayButton, qualityButton, audioButton, privacyButton, pointerLockButton, keySwapButton, clipboardButton, filesButton, fullscreenButton, disconnectButton, collapseButton] {
            btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        displayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        qualityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        audioButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        privacyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        pointerLockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        keySwapButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        clipboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        filesButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        fullscreenButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        disconnectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        collapseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),

            tintOverlay.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),

            pillButton.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            pillButton.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            pillButton.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            pillButton.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),

            barStack.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            barStack.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            barStack.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
        ])

        rebuildQualityMenu()
    }

    // MARK: - Positioning & Expand/Collapse

    public func updatePosition() {
        guard let owner = ownerWindow else { return }
        guard owner.isVisible && !owner.isMiniaturized else {
            orderOut(nil)
            return
        }

        let contentRectInWindow = owner.contentLayoutRect
        let contentScreenRect = owner.convertToScreen(contentRectInWindow)
        guard contentScreenRect.width > 0 else { return }

        let targetSize: NSSize
        if isExpanded {
            barStack.layoutSubtreeIfNeeded()
            let fittingW = max(680, barStack.fittingSize.width + 6)
            let clampedW = min(contentScreenRect.width - 24, fittingW)
            targetSize = NSSize(width: clampedW, height: Self.barHeight)
        } else {
            let pillW = max(195, min(260, pillButton.attributedTitle.size().width + 24))
            targetSize = NSSize(width: pillW, height: Self.pillHeight)
        }

        let x = contentScreenRect.minX + max(0, (contentScreenRect.width - targetSize.width) / 2.0)
        let y = contentScreenRect.maxY - targetSize.height - 6
        setFrame(NSRect(x: round(x), y: round(y), width: round(targetSize.width), height: round(targetSize.height)), display: true)
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        pillButton.isHidden = expanded
        barStack.isHidden = !expanded
        rootContainer.layer?.cornerRadius = expanded ? 10 : 12
        updatePosition()

        if expanded {
            scheduleAutoHide()
        } else {
            cancelAutoHide()
        }
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCollapseDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.isMenuOpen && !self.frame.contains(NSEvent.mouseLocation) {
                self.setExpanded(false)
            }
        }
    }

    private func cancelAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    // MARK: - Telemetry & State Updates

    public func updateHUD(stats: ClientStats) {
        let mbps = Double(stats.bitrateKbps) / 1000.0
        let rttText = stats.rttMs >= 0 ? "\(stats.rttMs) ms" : "-- ms"
        let summary = String(format: "%.0f fps · %.1f Mbps · %@", stats.fps, mbps, rttText)
        hudLabel.stringValue = summary
        pillButton.title = "▼  \(summary)"

        codecBadge.text = stats.codec.badgeText
        hwBadge.text = stats.isHardwareDecoded ? "HW" : "SW"
        hwBadge.updateColors(
            background: stats.isHardwareDecoded ? Theme.accentDim : Theme.warningDim,
            foreground: stats.isHardwareDecoded ? Theme.accent : Theme.warning
        )
        updatePosition()
    }

    public func updateDisplays(_ displays: [DisplayInfo], activeId: UInt32) {
        self.displays = displays
        self.activeDisplayId = activeId
        displayButton.isHidden = displays.count <= 1
        rebuildDisplayMenu()
        if isExpanded { updatePosition() }
    }

    public func updateHostOS(_ serverOs: String) {
        isWindowsHost = serverOs.lowercased().contains("win")
        keySwapButton.isHidden = !isWindowsHost
        if isExpanded { updatePosition() }
    }

    public func updateState(
        resolution: ResolutionTier? = nil,
        scaleMode: ScaleMode? = nil,
        fps: Int? = nil,
        fpsAuto: Bool? = nil,
        bitrateBps: Int? = nil,
        bitrateAuto: Bool? = nil,
        codec: VideoCodec? = nil,
        audioOn: Bool? = nil,
        volume: Float? = nil,
        privacyOn: Bool? = nil,
        pointerLocked: Bool? = nil,
        macWinSwapOn: Bool? = nil,
        clipboardSyncOn: Bool? = nil,
        isFullscreen: Bool? = nil
    ) {
        var needsMenuRebuild = false
        if let resolution { self.resolution = resolution; needsMenuRebuild = true }
        if let scaleMode { self.scaleMode = scaleMode; needsMenuRebuild = true }
        if let fps { self.fps = fps; needsMenuRebuild = true }
        if let fpsAuto { self.fpsAuto = fpsAuto; needsMenuRebuild = true }
        if let bitrateBps { self.bitrateBps = bitrateBps; needsMenuRebuild = true }
        if let bitrateAuto { self.bitrateAuto = bitrateAuto; needsMenuRebuild = true }
        if let codec { self.codec = codec; codecBadge.text = codec.badgeText; needsMenuRebuild = true }

        if let audioOn {
            self.audioOn = audioOn
            audioButton.title = audioOn ? "声音: 开" : "声音: 关"
            audioButton.buttonStyle = audioOn ? .toolbarActive : .toolbar
            volumeSlider.isEnabled = audioOn
        }
        if let volume {
            self.volume = volume
            volumeSlider.floatValue = volume
        }
        if let privacyOn {
            self.privacyOn = privacyOn
            privacyButton.buttonStyle = privacyOn ? .toolbarActive : .toolbar
        }
        if let pointerLocked {
            self.pointerLocked = pointerLocked
            pointerLockButton.title = pointerLocked ? "锁定中" : "游戏鼠标"
            pointerLockButton.buttonStyle = pointerLocked ? .toolbarActive : .toolbar
        }
        if let macWinSwapOn {
            self.macWinSwapOn = macWinSwapOn
            keySwapButton.buttonStyle = macWinSwapOn ? .toolbarActive : .toolbar
        }
        if let clipboardSyncOn {
            self.clipboardSyncOn = clipboardSyncOn
            clipboardButton.buttonStyle = clipboardSyncOn ? .toolbarActive : .toolbar
        }
        if let isFullscreen {
            self.isFullscreen = isFullscreen
            fullscreenButton.title = isFullscreen ? "窗口" : "全屏"
            fullscreenButton.buttonStyle = isFullscreen ? .toolbarActive : .toolbar
        }

        if needsMenuRebuild {
            rebuildQualityMenu()
        }
    }

    // MARK: - Menus

    private func rebuildQualityMenu() {
        qualityMenu.removeAllItems()

        // Resolution
        let resSub = NSMenu()
        for tier in ResolutionTier.allCases {
            let item = NSMenuItem(title: tier.displayName, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tier.rawValue
            item.state = (tier == resolution) ? .on : .off
            resSub.addItem(item)
        }
        let resRoot = NSMenuItem(title: "分辨率 (\(resolution.displayName))", action: nil, keyEquivalent: "")
        resRoot.submenu = resSub
        qualityMenu.addItem(resRoot)

        // Scale Mode
        let scaleSub = NSMenu()
        let scaleLabels: [(ScaleMode, String)] = [
            (.fit, "等比缩放 (Fit)"),
            (.stretch, "拉伸铺满 (Stretch)"),
            (.original, "原始 1:1 (Original)")
        ]
        for (mode, label) in scaleLabels {
            let item = NSMenuItem(title: label, action: #selector(selectScaleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == scaleMode) ? .on : .off
            scaleSub.addItem(item)
        }
        let scaleRoot = NSMenuItem(title: "缩放模式", action: nil, keyEquivalent: "")
        scaleRoot.submenu = scaleSub
        qualityMenu.addItem(scaleRoot)

        // FPS
        let fpsSub = NSMenu()
        let autoFpsItem = NSMenuItem(title: "自动 (\(fps) fps)", action: #selector(selectAutoFps), keyEquivalent: "")
        autoFpsItem.target = self
        autoFpsItem.state = fpsAuto ? .on : .off
        fpsSub.addItem(autoFpsItem)
        for val in [30, 60, 90, 120] {
            let item = NSMenuItem(title: "\(val) fps", action: #selector(selectFixedFps(_:)), keyEquivalent: "")
            item.target = self
            item.tag = val
            item.state = (!fpsAuto && fps == val) ? .on : .off
            fpsSub.addItem(item)
        }
        let fpsRoot = NSMenuItem(title: "帧率 (\(fpsAuto ? "自动" : "\(fps)fps"))", action: nil, keyEquivalent: "")
        fpsRoot.submenu = fpsSub
        qualityMenu.addItem(fpsRoot)

        // Bitrate
        let brSub = NSMenu()
        let autoBrItem = NSMenuItem(title: "自动 (\(bitrateBps / 1_000_000) Mbps)", action: #selector(selectAutoBitrate), keyEquivalent: "")
        autoBrItem.target = self
        autoBrItem.state = bitrateAuto ? .on : .off
        brSub.addItem(autoBrItem)
        for val in [2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000] {
            let item = NSMenuItem(title: "\(val / 1_000_000) Mbps", action: #selector(selectFixedBitrate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = val
            item.state = (!bitrateAuto && bitrateBps == val) ? .on : .off
            brSub.addItem(item)
        }
        let brRoot = NSMenuItem(title: "码率 (\(bitrateAuto ? "自动" : "\(bitrateBps / 1_000_000)Mbps"))", action: nil, keyEquivalent: "")
        brRoot.submenu = brSub
        qualityMenu.addItem(brRoot)

        // Codec
        let codecSub = NSMenu()
        for c in [VideoCodec.h264, VideoCodec.h265] {
            let item = NSMenuItem(title: c == .h264 ? "H.264 (AVC)" : "H.265 (HEVC)", action: #selector(selectCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = (c == codec) ? .on : .off
            codecSub.addItem(item)
        }
        let codecRoot = NSMenuItem(title: "视频编码 (\(codec.badgeText))", action: nil, keyEquivalent: "")
        codecRoot.submenu = codecSub
        qualityMenu.addItem(codecRoot)

        qualityMenu.addItem(.separator())

        let kfItem = NSMenuItem(title: "强制刷新关键帧 (Force Keyframe)", action: #selector(forceKeyframeTapped), keyEquivalent: "")
        kfItem.target = self
        qualityMenu.addItem(kfItem)

        let cadItem = NSMenuItem(title: "发送 Ctrl + Alt + Delete", action: #selector(ctrlAltDelTapped), keyEquivalent: "")
        cadItem.target = self
        qualityMenu.addItem(cadItem)

        let lockItem = NSMenuItem(title: "锁定远端屏幕 (Lock Screen)", action: #selector(lockScreenTapped), keyEquivalent: "")
        lockItem.target = self
        qualityMenu.addItem(lockItem)
    }

    private func rebuildDisplayMenu() {
        displayMenu.removeAllItems()
        for d in displays {
            let item = NSMenuItem(title: "\(d.name) (\(d.width)×\(d.height))", action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(d.id)
            item.state = (d.id == activeDisplayId) ? .on : .off
            displayMenu.addItem(item)
        }
    }

    private func popMenu(_ menu: NSMenu, under button: NSView) {
        isMenuOpen = true
        cancelAutoHide()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
        isMenuOpen = false
        if isExpanded {
            scheduleAutoHide()
        }
    }

    // MARK: - Actions

    @objc private func expandTapped() { setExpanded(true) }
    @objc private func collapseTapped() { setExpanded(false) }
    @objc private func showQualityMenu() { popMenu(qualityMenu, under: qualityButton) }
    @objc private func showDisplayMenu() { popMenu(displayMenu, under: displayButton) }
    @objc private func audioTapped() { onAudioToggled?(!audioOn) }
    @objc private func volumeSliderChanged() { onVolumeChanged?(volumeSlider.floatValue) }
    @objc private func privacyTapped() { onPrivacyToggled?(!privacyOn) }
    @objc private func pointerLockTapped() { onPointerLockToggled?() }
    @objc private func keySwapTapped() { onMacWinSwapToggled?(!macWinSwapOn) }
    @objc private func clipboardTapped() { onClipboardSyncToggled?(!clipboardSyncOn) }
    @objc private func filesTapped() { onFileTransferRequested?() }
    @objc private func fullscreenTapped() { onFullscreenToggled?() }
    @objc private func disconnectTapped() { onDisconnectRequested?() }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tier = ResolutionTier(rawValue: raw) {
            onResolutionChanged?(tier)
        }
    }

    @objc private func selectScaleMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ScaleMode(rawValue: raw) {
            onScaleModeChanged?(mode)
        }
    }

    @objc private func selectAutoFps() { onFpsChanged?(fps, true) }
    @objc private func selectFixedFps(_ sender: NSMenuItem) { onFpsChanged?(sender.tag, false) }
    @objc private func selectAutoBitrate() { onBitrateChanged?(bitrateBps, true) }
    @objc private func selectFixedBitrate(_ sender: NSMenuItem) { onBitrateChanged?(sender.tag, false) }

    @objc private func selectCodec(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = VideoCodec(rawValue: raw) {
            onCodecChanged?(c)
        }
    }

    @objc private func forceKeyframeTapped() { onForceKeyframe?() }
    @objc private func ctrlAltDelTapped() { onCtrlAltDel?() }
    @objc private func lockScreenTapped() { onLockScreen?() }
    @objc private func selectDisplay(_ sender: NSMenuItem) { onDisplaySelected?(UInt32(sender.tag)) }
}

// MARK: - HoverTrackingView

private final class HoverTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}
