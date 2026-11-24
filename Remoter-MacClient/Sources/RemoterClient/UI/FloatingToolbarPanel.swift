import AppKit

/// Borderless child `NSPanel` pinned to the top-center of `DesktopWindowController`.
/// Collapses to a compact translucent dark handle (`▼  控制栏`), expands on click/hover,
/// and auto-collapses after 3 seconds of mouse-exit inactivity.
public final class FloatingToolbarPanel: NSPanel {
    private static let pillHeight: CGFloat = 24
    private static let barHeight: CGFloat = 42
    private static let autoCollapseDelay: TimeInterval = 3.0

    // MARK: - Callbacks
    public var onQualityPresetChanged: ((QualityPreset) -> Void)?
    public var onSharpnessChanged: ((SharpnessLevel) -> Void)?
    public var onChromaToggled: ((ChromaMode) -> Void)?
    public var onHdrToggled: ((Bool) -> Void)?
    public var onToneMapToggled: ((Bool) -> Void)?
    public var onLowLatencyToggled: ((Bool) -> Void)?
    public var onToggleStatsHud: ((Bool) -> Void)?
    public var onResolutionChanged: ((ResolutionTier) -> Void)?
    public var onScaleModeChanged: ((ScaleMode) -> Void)?
    public var onFpsChanged: ((Int, Bool) -> Void)?
    public var onBitrateChanged: ((Int, Bool) -> Void)?
    public var onCodecChanged: ((VideoCodec) -> Void)?
    public var onForceKeyframe: (() -> Void)?
    public var onCtrlAltDel: (() -> Void)?
    public var onLockScreen: (() -> Void)?
    public var onPowerAction: ((String) -> Void)?
    public var onDisplaySelected: ((UInt32) -> Void)?
    public var onCycleDisplay: (() -> Void)?
    public var onVirtualDisplayToggled: ((Bool) -> Void)?
    public var onAudioToggled: ((Bool) -> Void)?
    public var onVolumeChanged: ((Float) -> Void)?
    public var onMicToggled: ((Bool) -> Void)?
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

    private var qualityPreset: QualityPreset = .auto
    private var sharpness: SharpnessLevel = .low
    private var chromaMode: ChromaMode = .yuv420
    private var hdrEnabled: Bool = false
    private var toneMapEnabled: Bool = false
    private var lowLatencyEnabled: Bool = false
    private var resolution: ResolutionTier = .native
    private var scaleMode: ScaleMode = .fit
    private var fps: Int = 60
    private var fpsAuto: Bool = true
    private var bitrateBps: Int = 8_000_000
    private var bitrateAuto: Bool = true
    private var codec: VideoCodec = .h264
    private var audioOn: Bool = true
    private var volume: Float = 1.0
    private var micOn: Bool = false
    private var privacyOn: Bool = false
    private var pointerLocked: Bool = false
    private var macWinSwapOn: Bool = true
    private var clipboardSyncOn: Bool = true
    private var isFullscreen: Bool = false
    private var statsHudVisible: Bool = true
    private var isWindowsHost: Bool = false
    private var virtualDisplayOn: Bool = false
    private var displays: [DisplayInfo] = []
    private var activeDisplayId: UInt32 = 0

    // MARK: - Views
    private let rootContainer = HoverTrackingView()

    // Collapsed pill
    private let pillButton = Theme.makeButton(title: "▼  控制栏", style: .ghost, fontSize: 11, weight: .medium)

    // Expanded bar
    private let barStack = NSStackView()

    private let displayButton = Theme.makeButton(title: "显示器 ▾", style: .toolbar, fontSize: 11.5)
    private let cycleDisplayButton = Theme.makeButton(title: "一键切屏", style: .toolbar, fontSize: 11.5)
    private let qualityButton = Theme.makeButton(title: "画质 ▾", style: .toolbar, fontSize: 11.5)
    private let audioButton = Theme.makeButton(title: "声音: 开", style: .toolbarActive, fontSize: 11.5)
    private let volumeSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let micButton = Theme.makeButton(title: "麦克风", style: .toolbar, fontSize: 11.5)
    private let privacyButton = Theme.makeButton(title: "隐私屏", style: .toolbar, fontSize: 11.5)
    private let pointerLockButton = Theme.makeButton(title: "游戏鼠标", style: .toolbar, fontSize: 11.5)
    private let keySwapButton = Theme.makeButton(title: "⌘↔Ctrl", style: .toolbarActive, fontSize: 11.5)
    private let clipboardButton = Theme.makeButton(title: "剪贴板", style: .toolbarActive, fontSize: 11.5)
    private let filesButton = Theme.makeButton(title: "文件", style: .toolbar, fontSize: 11.5)
    private let powerButton = Theme.makeButton(title: "电源 ▾", style: .toolbar, fontSize: 11.5)
    private let fullscreenButton = Theme.makeButton(title: "全屏", style: .toolbar, fontSize: 11.5)
    private let disconnectButton = Theme.makeButton(title: "断开", style: .danger, fontSize: 11.5, weight: .semibold)
    private let collapseButton = Theme.makeButton(title: "▲", style: .ghost, fontSize: 11)

    private let qualityMenu = NSMenu()
    private let displayMenu = NSMenu()
    private let powerMenu = NSMenu()

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

        cycleDisplayButton.target = self
        cycleDisplayButton.action = #selector(cycleDisplayTapped)
        cycleDisplayButton.toolTip = "一键切换至下一显示器"
        cycleDisplayButton.isHidden = true

        qualityButton.target = self
        qualityButton.action = #selector(showQualityMenu)

        audioButton.target = self
        audioButton.action = #selector(audioTapped)

        micButton.target = self
        micButton.action = #selector(micTapped)
        micButton.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "麦克风")
        micButton.imagePosition = .imageLeading
        micButton.toolTip = "开启/关闭本机麦克风回传到远端"

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

        powerButton.target = self
        powerButton.action = #selector(showPowerMenu)
        powerButton.toolTip = "远端电源控制（锁屏 / 休眠 / 重启）"

        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreenTapped)

        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)

        collapseButton.target = self
        collapseButton.action = #selector(collapseTapped)

        // Bar stack
        let sep2 = Theme.makeSeparator(vertical: true)
        sep2.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let controls: [NSView] = [
            displayButton, cycleDisplayButton, qualityButton,
            audioButton, volumeSlider, micButton,
            privacyButton, pointerLockButton, keySwapButton, clipboardButton, filesButton, powerButton,
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

        for btn in [displayButton, cycleDisplayButton, qualityButton, audioButton, micButton, privacyButton, pointerLockButton, keySwapButton, clipboardButton, filesButton, powerButton, fullscreenButton, disconnectButton, collapseButton] {
            btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        displayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        cycleDisplayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        qualityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        audioButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        micButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        privacyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        pointerLockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        keySwapButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        clipboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        filesButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        powerButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        fullscreenButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        disconnectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        collapseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        NSLayoutConstraint.activate([
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
        rebuildPowerMenu()
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
            let fittingW = max(540, barStack.fittingSize.width + 6)
            let clampedW = min(contentScreenRect.width - 24, fittingW)
            targetSize = NSSize(width: clampedW, height: Self.barHeight)
        } else {
            let pillW = max(92, min(140, pillButton.attributedTitle.size().width + 26))
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
        rootContainer.cornerRadius = expanded ? 10 : 12
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

    // MARK: - State Updates

    public func updateDisplays(_ displays: [DisplayInfo], activeId: UInt32) {
        self.displays = displays
        self.activeDisplayId = activeId
        let hasMultiple = displays.count > 1
        displayButton.isHidden = !hasMultiple
        cycleDisplayButton.isHidden = !hasMultiple
        rebuildDisplayMenu()
        rebuildQualityMenu()
        if isExpanded { updatePosition() }
    }

    public func updateHostOS(_ serverOs: String) {
        isWindowsHost = serverOs.lowercased().contains("win")
        keySwapButton.isHidden = !isWindowsHost
        if isExpanded { updatePosition() }
    }

    public func updateState(
        qualityPreset: QualityPreset? = nil,
        sharpness: SharpnessLevel? = nil,
        chromaMode: ChromaMode? = nil,
        hdrEnabled: Bool? = nil,
        toneMapEnabled: Bool? = nil,
        lowLatencyEnabled: Bool? = nil,
        resolution: ResolutionTier? = nil,
        scaleMode: ScaleMode? = nil,
        fps: Int? = nil,
        fpsAuto: Bool? = nil,
        bitrateBps: Int? = nil,
        bitrateAuto: Bool? = nil,
        codec: VideoCodec? = nil,
        audioOn: Bool? = nil,
        volume: Float? = nil,
        micOn: Bool? = nil,
        privacyOn: Bool? = nil,
        pointerLocked: Bool? = nil,
        macWinSwapOn: Bool? = nil,
        clipboardSyncOn: Bool? = nil,
        isFullscreen: Bool? = nil,
        statsHudVisible: Bool? = nil,
        virtualDisplayOn: Bool? = nil
    ) {
        var needsMenuRebuild = false
        if let qualityPreset { self.qualityPreset = qualityPreset; needsMenuRebuild = true }
        if let sharpness { self.sharpness = sharpness; needsMenuRebuild = true }
        if let chromaMode { self.chromaMode = chromaMode; needsMenuRebuild = true }
        if let hdrEnabled { self.hdrEnabled = hdrEnabled; needsMenuRebuild = true }
        if let toneMapEnabled { self.toneMapEnabled = toneMapEnabled; needsMenuRebuild = true }
        if let lowLatencyEnabled { self.lowLatencyEnabled = lowLatencyEnabled; needsMenuRebuild = true }
        if let resolution { self.resolution = resolution; needsMenuRebuild = true }
        if let scaleMode { self.scaleMode = scaleMode; needsMenuRebuild = true }
        if let fps { self.fps = fps; needsMenuRebuild = true }
        if let fpsAuto { self.fpsAuto = fpsAuto; needsMenuRebuild = true }
        if let bitrateBps { self.bitrateBps = bitrateBps; needsMenuRebuild = true }
        if let bitrateAuto { self.bitrateAuto = bitrateAuto; needsMenuRebuild = true }
        if let codec { self.codec = codec; needsMenuRebuild = true }
        if let statsHudVisible { self.statsHudVisible = statsHudVisible; needsMenuRebuild = true }
        if let virtualDisplayOn { self.virtualDisplayOn = virtualDisplayOn; needsMenuRebuild = true }

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
        if let micOn {
            self.micOn = micOn
            micButton.buttonStyle = micOn ? .toolbarActive : .toolbar
            micButton.image = NSImage(systemSymbolName: micOn ? "mic" : "mic.slash", accessibilityDescription: "麦克风")
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

    private func formatBitrate(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000.0
        if mbps.rounded() == mbps {
            return "\(Int(mbps))Mbps"
        }
        return String(format: "%.1fMbps", mbps)
    }

    private func rebuildQualityMenu() {
        qualityMenu.removeAllItems()

        // 1. Multi-display picker + 一键切屏 (only when >1 display)
        if displays.count > 1 {
            let dispSub = NSMenu()
            for d in displays {
                let item = NSMenuItem(title: "\(d.name) (\(d.width)×\(d.height))", action: #selector(selectDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(d.id)
                item.state = (d.id == activeDisplayId) ? .on : .off
                dispSub.addItem(item)
            }
            let activeName = displays.first(where: { $0.id == activeDisplayId })?.name ?? "显示器"
            let dispRoot = NSMenuItem(title: "显示器 (\(activeName))", action: nil, keyEquivalent: "")
            dispRoot.submenu = dispSub
            qualityMenu.addItem(dispRoot)

            let cycleItem = NSMenuItem(title: "一键切屏", action: #selector(cycleDisplayTapped), keyEquivalent: "")
            cycleItem.target = self
            qualityMenu.addItem(cycleItem)

            qualityMenu.addItem(.separator())
        }

        // 2. 画质预设: 自动 / 流畅 / 高清 / 原画
        let presetHeaderTitle = qualityPreset == .auto
            ? "画质预设 · 自动 (\(fps)fps · \(formatBitrate(bitrateBps)))"
            : "画质预设"
        let presetHeader = NSMenuItem(title: presetHeaderTitle, action: nil, keyEquivalent: "")
        presetHeader.isEnabled = false
        qualityMenu.addItem(presetHeader)

        let presetItems: [(QualityPreset, String)] = [
            (.auto,     "自动"),
            (.smooth,   "流畅 (30fps · 4Mbps)"),
            (.hd,       "高清 (60fps · 8Mbps)"),
            (.original, "原画 (120fps · 25Mbps)")
        ]
        for (preset, title) in presetItems {
            let item = NSMenuItem(title: title, action: #selector(selectQualityPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = (preset == qualityPreset) ? .on : .off
            qualityMenu.addItem(item)
        }

        qualityMenu.addItem(.separator())

        // 3. 真彩 4:4:4 & HDR 10-bit toggles
        let chromaItem = NSMenuItem(title: "真彩 4:4:4", action: #selector(toggleChromaTapped), keyEquivalent: "")
        chromaItem.target = self
        chromaItem.state = (chromaMode == .yuv444) ? .on : .off
        qualityMenu.addItem(chromaItem)

        let hdrItem = NSMenuItem(title: "HDR 10-bit", action: #selector(toggleHdrTapped), keyEquivalent: "")
        hdrItem.target = self
        hdrItem.state = hdrEnabled ? .on : .off
        qualityMenu.addItem(hdrItem)

        let vdispItem = NSMenuItem(title: "🖥️ 虚拟扩展屏", action: #selector(toggleVirtualDisplayTapped), keyEquivalent: "")
        vdispItem.target = self
        vdispItem.state = virtualDisplayOn ? .on : .off
        qualityMenu.addItem(vdispItem)

        let statsHudItem = NSMenuItem(title: "性能浮窗", action: #selector(toggleStatsHudTapped), keyEquivalent: "")
        statsHudItem.target = self
        statsHudItem.state = statsHudVisible ? .on : .off
        qualityMenu.addItem(statsHudItem)

        qualityMenu.addItem(.separator())

        // 4. Collapsible 高级设置 submenu (collapsed by default)
        let advMenu = NSMenu()

        // 分辨率
        let resSub = NSMenu()
        let resOrder: [ResolutionTier] = [.native, .match, .res1080, .res2k]
        for tier in resOrder {
            let item = NSMenuItem(title: tier.displayName, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tier.rawValue
            item.state = (tier == resolution) ? .on : .off
            resSub.addItem(item)
        }
        let resRoot = NSMenuItem(title: "分辨率 (\(resolution.displayName))", action: nil, keyEquivalent: "")
        resRoot.submenu = resSub
        advMenu.addItem(resRoot)

        // 缩放模式
        let scaleSub = NSMenu()
        let scaleLabels: [(ScaleMode, String)] = [
            (.fit, "等比缩放"),
            (.stretch, "拉伸全屏"),
            (.original, "原始1:1")
        ]
        for (mode, label) in scaleLabels {
            let item = NSMenuItem(title: label, action: #selector(selectScaleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == scaleMode) ? .on : .off
            scaleSub.addItem(item)
        }
        let scaleRoot = NSMenuItem(title: "缩放模式 (\(scaleMode.displayName))", action: nil, keyEquivalent: "")
        scaleRoot.submenu = scaleSub
        advMenu.addItem(scaleRoot)

        // 手动帧率
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
        let fpsRoot = NSMenuItem(title: "手动帧率 (\(fpsAuto ? "自动" : "\(fps) fps"))", action: nil, keyEquivalent: "")
        fpsRoot.submenu = fpsSub
        advMenu.addItem(fpsRoot)

        // 手动码率
        let brSub = NSMenu()
        let autoBrItem = NSMenuItem(title: "自动 (\(formatBitrate(bitrateBps)))", action: #selector(selectAutoBitrate), keyEquivalent: "")
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
        let brRoot = NSMenuItem(title: "手动码率 (\(bitrateAuto ? "自动" : formatBitrate(bitrateBps)))", action: nil, keyEquivalent: "")
        brRoot.submenu = brSub
        advMenu.addItem(brRoot)

        // 锐化强度
        let sharpSub = NSMenu()
        for level in SharpnessLevel.allCases {
            let item = NSMenuItem(title: level.displayName, action: #selector(selectSharpness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.rawValue
            item.state = (level == sharpness) ? .on : .off
            sharpSub.addItem(item)
        }
        let sharpRoot = NSMenuItem(title: "锐化强度 (\(sharpness.displayName))", action: nil, keyEquivalent: "")
        sharpRoot.submenu = sharpSub
        advMenu.addItem(sharpRoot)

        // 编解码器
        let codecSub = NSMenu()
        for c in [VideoCodec.h264, VideoCodec.h265] {
            let item = NSMenuItem(title: c == .h264 ? "H.264" : "H.265", action: #selector(selectCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = (c == codec) ? .on : .off
            codecSub.addItem(item)
        }
        let codecRoot = NSMenuItem(title: "编解码器 (\(codec.badgeText))", action: nil, keyEquivalent: "")
        codecRoot.submenu = codecSub
        advMenu.addItem(codecRoot)

        advMenu.addItem(.separator())

        // 零缓冲极速
        let lowLatItem = NSMenuItem(title: "零缓冲极速", action: #selector(toggleLowLatencyTapped), keyEquivalent: "")
        lowLatItem.target = self
        lowLatItem.state = lowLatencyEnabled ? .on : .off
        advMenu.addItem(lowLatItem)

        // SDR 色调映射 (when HDR on)
        if hdrEnabled {
            let toneMapItem = NSMenuItem(title: "SDR 色调映射", action: #selector(toggleToneMapTapped), keyEquivalent: "")
            toneMapItem.target = self
            toneMapItem.state = toneMapEnabled ? .on : .off
            advMenu.addItem(toneMapItem)
        }

        let advRoot = NSMenuItem(title: "高级设置", action: nil, keyEquivalent: "")
        advRoot.submenu = advMenu
        qualityMenu.addItem(advRoot)

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
    @objc private func showPowerMenu() { popMenu(powerMenu, under: powerButton) }
    @objc private func audioTapped() { onAudioToggled?(!audioOn) }
    @objc private func volumeSliderChanged() { onVolumeChanged?(volumeSlider.floatValue) }
    @objc private func micTapped() { onMicToggled?(!micOn) }
    @objc private func privacyTapped() { onPrivacyToggled?(!privacyOn) }
    @objc private func pointerLockTapped() { onPointerLockToggled?() }
    @objc private func keySwapTapped() { onMacWinSwapToggled?(!macWinSwapOn) }
    @objc private func clipboardTapped() { onClipboardSyncToggled?(!clipboardSyncOn) }
    @objc private func filesTapped() { onFileTransferRequested?() }
    @objc private func fullscreenTapped() { onFullscreenToggled?() }
    @objc private func disconnectTapped() { onDisconnectRequested?() }

    @objc private func selectQualityPreset(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let preset = QualityPreset(rawValue: raw) {
            onQualityPresetChanged?(preset)
        }
    }

    @objc private func selectSharpness(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let level = SharpnessLevel(rawValue: raw) {
            onSharpnessChanged?(level)
        }
    }

    @objc private func toggleChromaTapped() {
        let next: ChromaMode = (chromaMode == .yuv444) ? .yuv420 : .yuv444
        onChromaToggled?(next)
    }

    @objc private func toggleHdrTapped() {
        onHdrToggled?(!hdrEnabled)
    }

    @objc private func toggleToneMapTapped() {
        onToneMapToggled?(!toneMapEnabled)
    }

    @objc private func toggleLowLatencyTapped() {
        onLowLatencyToggled?(!lowLatencyEnabled)
    }

    @objc private func toggleStatsHudTapped() {
        onToggleStatsHud?(!statsHudVisible)
    }

    @objc private func cycleDisplayTapped() {
        onCycleDisplay?()
    }

    @objc private func toggleVirtualDisplayTapped() {
        onVirtualDisplayToggled?(!virtualDisplayOn)
    }

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

    private func rebuildPowerMenu() {
        powerMenu.removeAllItems()
        let items: [(String, String)] = [
            ("🔒 锁屏", "lock"),
            ("🌙 休眠", "sleep"),
            ("🔄 重启", "restart")
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: #selector(powerActionTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            powerMenu.addItem(item)
        }
    }

    @objc private func powerActionTapped(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? String {
            onPowerAction?(action)
        }
    }

    @objc private func forceKeyframeTapped() { onForceKeyframe?() }
    @objc private func ctrlAltDelTapped() { onCtrlAltDel?() }
    @objc private func lockScreenTapped() { onLockScreen?() }
    @objc private func selectDisplay(_ sender: NSMenuItem) { onDisplaySelected?(UInt32(sender.tag)) }
}

// MARK: - HoverTrackingView

private final class HoverTrackingView: NSView {
    private static let backdropColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.88)
    private static let borderStrokeColor = NSColor.white.withAlphaComponent(0.12)

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var cornerRadius: CGFloat = 12 {
        didSet {
            if cornerRadius != oldValue {
                needsDisplay = true
            }
        }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = Theme.darkAppearance
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = Self.backdropColor.cgColor
        layer.cornerRadius = cornerRadius
        layer.borderColor = Self.borderStrokeColor.cgColor
        layer.borderWidth = 1
        layer.masksToBounds = true
    }

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
