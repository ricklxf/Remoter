import AppKit
import VideoToolbox

/// Full dark native macOS remote desktop window (`1280x800`, resizable, native fullscreen).
/// Hosts `MetalRendererView` inside an input & file-drop container view, wires `VideoDecoder`,
/// `AudioPlayer`, `ClipboardSync`, `InputManager`, `RemoterConnection`, `FloatingToolbarPanel`,
/// `FileTransferSheetController`, connection/reconnecting overlay banner, and non-blocking bottom toasts.
public final class DesktopWindowController: NSWindowController, NSWindowDelegate {
    public var onClosed: ((_ errorMessage: String?) -> Void)?

    private let connectParams: ConnectParams
    private var settings: ClientSettings

    // Core subsystems
    private let connection: RemoterConnection
    private let videoDecoder = VideoDecoder()
    private let audioPlayer = AudioPlayer()
    private let micCapturer = MicCapturer()
    private let clipboardSync = ClipboardSync()
    private let rendererView: MetalRendererView
    private let inputManager: InputManager

    // UI components
    private let canvasContainer = RemoteCanvasContainerView()
    private let statsHudView = StatsHudOverlayView()
    private var toolbarPanel: FloatingToolbarPanel?
    private var fileTransferSheet: FileTransferSheetController?

    // Overlay banner (connecting / authenticating / reconnecting)
    private let overlayCard = Theme.makeCard(background: Theme.surface.withAlphaComponent(0.95), cornerRadius: 12)
    private let overlaySpinner = NSProgressIndicator()
    private let overlayTitle = Theme.makeLabel("正在连接…", size: 15, weight: .semibold, color: Theme.textPrimary)
    private let overlaySubtitle = Theme.makeLabel("", size: 12, color: Theme.textMuted)
    private let overlayCancelButton = Theme.makeButton(title: "取消", style: .danger, fontSize: 12)

    // Non-blocking bottom toast
    private let toastCard = Theme.makeCard(background: Theme.elevated.withAlphaComponent(0.95), cornerRadius: 8)
    private let toastLabel = Theme.makeLabel("", size: 12.5, weight: .medium, color: Theme.textPrimary)
    private var toastTimer: Timer?

    // Floating IME composition echo pill (bottom-center, matching Web RemoteCanvas.tsx)
    private let imeEchoCard = Theme.makeCard(background: Theme.elevated.withAlphaComponent(0.95), cornerRadius: 8)
    private let imeEchoLabel = Theme.makeLabel("", size: 14, weight: .medium, color: Theme.textPrimary)

    // Translucent Drag & Drop upload overlay
    private let dropOverlayView = NSView()
    private let dropOverlayCard = Theme.makeCard(background: Theme.surface.withAlphaComponent(0.92), cornerRadius: 14)
    private let dropOverlayLabel = Theme.makeLabel("📁 松开即上传文件或文件夹到远端", size: 16, weight: .semibold, color: Theme.textPrimary)
    private var imeEchoBottomConstraint: NSLayoutConstraint?

    // Clipboard file sync state
    private var clipboardFileSyncTask: Task<Void, Never>?
    private var remoteClipboardDownloadTask: Task<Void, Never>?
    private static let maxLocalClipboardUploadBytes: Int64 = 100 * 1024 * 1024
    private static let maxRemoteClipboardDownloadBytes: Int64 = 50 * 1024 * 1024

    // Session state
    private static let qualityPresetDefaultsKey = "remoter_quality_preset"
    private static let matchLocalHiDPIDefaultsKey = "remoter_match_local_hidpi"
    private var isTornDown = false
    private var closeErrorMessage: String?
    private var privacyEnabled = false
    private var virtualDisplayEnabled = false
    private var micEnabled = false
    private var isFullscreen = false
    private var statsHudVisible = true
    private var hasSentCodecCaps = false
    private var hasSentMatchLocalHiDPI = false
    private var manualCodecSelected = false
    private var displays: [DisplayInfo] = []
    private var activeDisplayId: UInt32 = 0

    public init(params: ConnectParams) {
        self.connectParams = params
        var loadedSettings = DeviceStore.shared.getSettings()
        if let rawPreset = UserDefaults.standard.string(forKey: Self.qualityPresetDefaultsKey),
           let savedPreset = QualityPreset(rawValue: rawPreset) {
            loadedSettings.qualityPreset = savedPreset
        }
        if UserDefaults.standard.object(forKey: Self.matchLocalHiDPIDefaultsKey) != nil {
            loadedSettings.matchLocalHiDPI = UserDefaults.standard.bool(forKey: Self.matchLocalHiDPIDefaultsKey)
        }
        self.settings = loadedSettings

        let downloadDir: URL? = settings.downloadDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.connection = RemoterConnection(downloadDirectory: downloadDir)
        self.rendererView = MetalRendererView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        self.inputManager = InputManager(connection: connection, rendererView: rendererView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let label = params.label ?? (params.mode == .relay ? "Relay" : "\(params.host):\(params.port)")
        window.title = "Remoter — \(label)"
        window.backgroundColor = Theme.videoBackground
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.center()

        super.init(window: window)
        window.delegate = self

        setupUI()
        wireSubsystems()
        applyInitialSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public func startSession() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(rendererView)

        if let win = window, let toolbar = toolbarPanel {
            if toolbar.parent !== win {
                win.addChildWindow(toolbar, ordered: .above)
            }
            toolbar.updatePosition()
            toolbar.orderFront(nil)
        }

        let targetDesc = connectParams.mode == .relay
            ? (connectParams.sessionId ?? "Relay")
            : "\(connectParams.host):\(connectParams.port)"
        showOverlay(title: "正在连接…", subtitle: targetDesc)
        connection.connect(connectParams)
    }

    public func disconnectAndClose(errorMessage: String? = nil) {
        closeErrorMessage = errorMessage
        teardown()
        window?.close()
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        window?.backgroundColor = Theme.videoBackground

        canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        canvasContainer.inputManager = inputManager
        canvasContainer.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        rendererView.translatesAutoresizingMaskIntoConstraints = false
        rendererView.inputManager = inputManager
        rendererView.onFileDragHoverChanged = { [weak self] hovering in
            self?.setDropOverlayVisible(hovering)
        }
        rendererView.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }
        rendererView.scaleMode = settings.scaleMode
        rendererView.sharpness = settings.sharpness
        rendererView.toneMap = settings.toneMapEnabled
        rendererView.targetFPS = settings.fps
        rendererView.vsyncEnabled = settings.vsyncEnabled

        canvasContainer.addSubview(rendererView)
        contentView.addSubview(canvasContainer)

        statsHudView.isHidden = !statsHudVisible
        contentView.addSubview(statsHudView)

        NSLayoutConstraint.activate([
            canvasContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            canvasContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            canvasContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            canvasContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            rendererView.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            rendererView.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            rendererView.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            rendererView.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor),

            statsHudView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            statsHudView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        setupOverlayBanner(in: contentView)
        setupToast(in: contentView)
        setupImeEcho(in: contentView)
        setupDropOverlay(in: contentView)

        if let win = window {
            let toolbar = FloatingToolbarPanel(ownerWindow: win)
            self.toolbarPanel = toolbar
            wireToolbar(toolbar)
        }
    }

    private func setupOverlayBanner(in container: NSView) {
        overlaySpinner.style = .spinning
        overlaySpinner.controlSize = .regular
        overlaySpinner.translatesAutoresizingMaskIntoConstraints = false

        overlayCancelButton.target = self
        overlayCancelButton.action = #selector(cancelOverlayTapped)

        let textStack = NSStackView(views: [overlayTitle, overlaySubtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [overlaySpinner, textStack, overlayCancelButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        overlayCancelButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        overlayCancelButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        overlayCard.addSubview(row)
        overlayCard.isHidden = true
        container.addSubview(overlayCard)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: overlayCard.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: overlayCard.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: overlayCard.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: overlayCard.bottomAnchor, constant: -14),

            overlayCard.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlayCard.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            overlayCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func setupToast(in container: NSView) {
        toastCard.addSubview(toastLabel)
        toastCard.isHidden = true
        toastCard.alphaValue = 0
        container.addSubview(toastCard)

        NSLayoutConstraint.activate([
            toastLabel.leadingAnchor.constraint(equalTo: toastCard.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastCard.trailingAnchor, constant: -14),
            toastLabel.topAnchor.constraint(equalTo: toastCard.topAnchor, constant: 8),
            toastLabel.bottomAnchor.constraint(equalTo: toastCard.bottomAnchor, constant: -8),

            toastCard.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toastCard.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
    }

    private func setupImeEcho(in container: NSView) {
        imeEchoCard.strokeColor = Theme.accent.withAlphaComponent(0.6)
        imeEchoCard.strokeWidth = 1
        imeEchoCard.addSubview(imeEchoLabel)
        imeEchoCard.isHidden = true
        container.addSubview(imeEchoCard)

        let bottomConstraint = imeEchoCard.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -140)
        self.imeEchoBottomConstraint = bottomConstraint

        NSLayoutConstraint.activate([
            imeEchoLabel.leadingAnchor.constraint(equalTo: imeEchoCard.leadingAnchor, constant: 14),
            imeEchoLabel.trailingAnchor.constraint(equalTo: imeEchoCard.trailingAnchor, constant: -14),
            imeEchoLabel.topAnchor.constraint(equalTo: imeEchoCard.topAnchor, constant: 6),
            imeEchoLabel.bottomAnchor.constraint(equalTo: imeEchoCard.bottomAnchor, constant: -6),

            imeEchoCard.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottomConstraint,
        ])
    }

    private func setupDropOverlay(in container: NSView) {
        dropOverlayView.translatesAutoresizingMaskIntoConstraints = false
        dropOverlayView.wantsLayer = true
        dropOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dropOverlayView.isHidden = true

        dropOverlayCard.strokeColor = Theme.accent
        dropOverlayCard.strokeWidth = 2
        dropOverlayCard.addSubview(dropOverlayLabel)
        dropOverlayView.addSubview(dropOverlayCard)
        container.addSubview(dropOverlayView)

        NSLayoutConstraint.activate([
            dropOverlayView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dropOverlayView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dropOverlayView.topAnchor.constraint(equalTo: container.topAnchor),
            dropOverlayView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dropOverlayLabel.leadingAnchor.constraint(equalTo: dropOverlayCard.leadingAnchor, constant: 28),
            dropOverlayLabel.trailingAnchor.constraint(equalTo: dropOverlayCard.trailingAnchor, constant: -28),
            dropOverlayLabel.topAnchor.constraint(equalTo: dropOverlayCard.topAnchor, constant: 18),
            dropOverlayLabel.bottomAnchor.constraint(equalTo: dropOverlayCard.bottomAnchor, constant: -18),

            dropOverlayCard.centerXAnchor.constraint(equalTo: dropOverlayView.centerXAnchor),
            dropOverlayCard.centerYAnchor.constraint(equalTo: dropOverlayView.centerYAnchor),
        ])
    }

    private func setDropOverlayVisible(_ visible: Bool) {
        dropOverlayView.isHidden = !visible
    }

    private func updateImeEchoBottomMargin() {
        var bottomMargin: CGFloat = 140
        if let win = window, let contentView = win.contentView,
           let screen = win.screen ?? NSScreen.main {
            let contentBottomWin = contentView.convert(NSRect(x: 0, y: 0, width: 1, height: 1), to: nil)
            let contentBottomScreenY = win.convertToScreen(contentBottomWin).minY
            let minRequiredScreenY = screen.visibleFrame.minY + 120
            let neededMargin = minRequiredScreenY - contentBottomScreenY
            let maxMargin = max(140, contentView.bounds.height - 60)
            bottomMargin = min(max(140, neededMargin), maxMargin)
        }
        imeEchoBottomConstraint?.constant = -bottomMargin
    }

    private func updateImeEcho(_ text: String) {
        if text.isEmpty {
            imeEchoLabel.stringValue = ""
            imeEchoCard.isHidden = true
        } else {
            imeEchoLabel.stringValue = text
            imeEchoCard.isHidden = false
            updateImeEchoBottomMargin()
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Subsystem Wiring

    private func wireSubsystems() {
        // Controller-side native IME -> text_input + bottom-center echo pill
        rendererView.onImeTextCommitted = { [weak self] text in
            self?.connection.sendTextInput(text)
        }
        rendererView.onImeCompositionChanged = { [weak self] text in
            if Thread.isMainThread {
                self?.updateImeEcho(text)
            } else {
                DispatchQueue.main.async {
                    self?.updateImeEcho(text)
                }
            }
        }
        rendererView.imeCandidateAnchorRectProvider = { [weak self] in
            guard let self, let win = self.window else { return nil }
            if !self.imeEchoCard.isHidden {
                win.contentView?.layoutSubtreeIfNeeded()
                let winRect = self.imeEchoCard.convert(self.imeEchoCard.bounds, to: nil)
                let cardScreenRect = win.convertToScreen(winRect)
                // Return the full card rect so macOS TSM knows the exact text box height
                // and snaps the candidate bar flush below minY (or flush above maxY if flipped).
                return cardScreenRect
            }
            let viewBounds = self.canvasContainer.bounds
            let bottomMargin = abs(self.imeEchoBottomConstraint?.constant ?? -140)
            let anchorLocal = NSRect(x: viewBounds.midX, y: bottomMargin, width: 1, height: 1)
            let winRect = self.canvasContainer.convert(anchorLocal, to: nil)
            return win.convertToScreen(winRect)
        }

        // Video decode -> Metal render
        videoDecoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.rendererView.updateFrame(pixelBuffer)
        }
        videoDecoder.onRequestKeyframe = { [weak self] in
            self?.connection.sendRequestKeyframe()
        }

        // Telemetry providers
        connection.decodeMsProvider = { [weak self] in
            self?.videoDecoder.lastDecodeMs ?? 0
        }
        connection.isHardwareDecodedProvider = { [weak self] in
            self?.videoDecoder.isHardwareAccelerated ?? false
        }

        // Video & Audio packets (hot paths, stay off main thread)
        connection.onVideoFrame = { [weak self] packet in
            self?.videoDecoder.decode(packet)
        }
        connection.onAudioFrame = { [weak self] packet in
            self?.audioPlayer.enqueue(packet)
        }
        micCapturer.onPcmChunk = { [weak self] pcm in
            self?.connection.sendMicPcm(pcm)
        }

        // Pointer lock feedback & paste shortcut clipboard file sync
        inputManager.onPointerLockChanged = { [weak self] locked in
            DispatchQueue.main.async {
                self?.toolbarPanel?.updateState(pointerLocked: locked)
                self?.showToast(locked ? "已开启游戏鼠标 (⌃⌥↩ 退出)" : "已退出游戏鼠标")
            }
        }
        inputManager.onPasteShortcut = { [weak self] in
            self?.clipboardSync.checkLocalClipboardFilesNow()
        }
        clipboardSync.onLocalClipboardFilesChanged = { [weak self] urls, _ in
            self?.syncLocalClipboardFilesToRemote(urls: urls)
        }

        // Connection state
        connection.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionState(state)
            }
        }

        connection.onServerHello = { [weak self] hello in
            DispatchQueue.main.async {
                guard let self else { return }
                let hostName = hello.computerName.isEmpty ? self.connectParams.host : hello.computerName
                self.window?.title = "Remoter — \(hostName)"
                self.toolbarPanel?.updateHostOS(hello.os)

                let isWin = hello.os.lowercased().contains("win")
                let effectiveSwap = isWin && self.settings.macWinKeySwap
                self.inputManager.swapMacToWinModifiers = effectiveSwap
                self.toolbarPanel?.updateState(macWinSwapOn: effectiveSwap)

                if self.connectParams.mode == .direct {
                    DeviceStore.shared.updateMachineInfo(
                        host: self.connectParams.host,
                        port: self.connectParams.port,
                        computerName: hello.computerName,
                        modelId: hello.modelId,
                        serverOs: hello.os
                    )
                }
            }
        }

        connection.onAuthSucceeded = { [weak self] username, token in
            DispatchQueue.main.async {
                guard let self, self.connectParams.mode == .direct, self.connectParams.rememberDevice else { return }
                DeviceStore.shared.updateToken(
                    host: self.connectParams.host,
                    port: self.connectParams.port,
                    username: username,
                    token: token
                )
            }
        }

        connection.onStreamStarted = { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hideOverlay()
                self.displays = info.displays
                self.activeDisplayId = info.activeDisplayId
                self.toolbarPanel?.updateDisplays(info.displays, activeId: info.activeDisplayId)
                self.toolbarPanel?.updateState(fps: info.fps, codec: info.codec)
                self.rendererView.targetFPS = max(30, info.fps)

                self.applyQualityPreset(self.settings.qualityPreset, sendToServer: true, showToastMessage: false)
                if self.settings.chromaMode == .yuv444 {
                    self.connection.sendChroma(.yuv444)
                }
                if self.settings.hdrEnabled {
                    self.connection.sendHdr(enabled: true)
                }
                if self.settings.lowLatencyEnabled {
                    self.connection.sendLowLatency(true)
                }
                if self.settings.matchLocalHiDPI && !self.hasSentMatchLocalHiDPI {
                    self.hasSentMatchLocalHiDPI = true
                    self.sendMatchLocalHiDPI()
                }

                if !self.hasSentCodecCaps {
                    self.hasSentCodecCaps = true
                    if !self.manualCodecSelected {
                        let hevcHW = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
                        self.connection.sendCodecCaps(hevcHW ? ["h265", "h264"] : ["h264"])
                    }
                }

                if self.settings.audioEnabled {
                    self.audioPlayer.start()
                    self.connection.sendSetAudio(enabled: true)
                }
                self.clipboardSync.isEnabled = self.settings.clipboardSyncEnabled
                self.clipboardSync.start(connection: self.connection)
                self.connection.setClipboardSyncEnabled(self.settings.clipboardSyncEnabled)
                self.connection.setReverseClipboardActive(self.settings.clipboardSyncEnabled)
                if self.settings.clipboardSyncEnabled {
                    self.clipboardSync.syncNow()
                }
            }
        }

        connection.onCodecChanged = { [weak self] codec in
            DispatchQueue.main.async {
                self?.toolbarPanel?.updateState(codec: codec)
                self?.showToast("视频编码已切换为 \(codec.badgeText)")
            }
        }

        connection.onQualityActiveChanged = { [weak self] fps, bitrate in
            DispatchQueue.main.async {
                self?.toolbarPanel?.updateState(fps: fps, bitrateBps: bitrate)
            }
        }

        connection.onChromaActiveChanged = { [weak self] mode in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.chromaMode = mode
                DeviceStore.shared.saveSettings(self.settings)
                self.toolbarPanel?.updateState(chromaMode: mode)
                self.showToast(mode == .yuv444 ? "真彩 4:4:4 已启用" : "已切换为 4:2:0")
            }
        }

        connection.onHdrActiveChanged = { [weak self] enabled in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.hdrEnabled = enabled
                if !enabled {
                    self.settings.toneMapEnabled = false
                    self.rendererView.toneMap = false
                }
                DeviceStore.shared.saveSettings(self.settings)
                self.toolbarPanel?.updateState(hdrEnabled: enabled, toneMapEnabled: self.settings.toneMapEnabled)
                self.showToast(enabled ? "HDR 10-bit 已启用" : "HDR 10-bit 已关闭")
            }
        }

        connection.onForceCanvasChanged = { _ in
            // Native Metal renderer always draws via Metal; acknowledged cleanly.
        }

        connection.onVirtualDisplayActiveChanged = { [weak self] enabled in
            DispatchQueue.main.async {
                guard let self else { return }
                self.virtualDisplayEnabled = enabled
                self.toolbarPanel?.updateState(virtualDisplayOn: enabled)
                self.showToast(enabled ? "虚拟扩展屏已开启" : "虚拟扩展屏已关闭")
            }
        }

        connection.onMicStatus = { [weak self] available, enabled, device, reason in
            DispatchQueue.main.async {
                guard let self else { return }
                if !available {
                    self.micCapturer.stop()
                    self.micEnabled = false
                    self.toolbarPanel?.updateState(micOn: false)
                    if reason == "no_virtual_audio_device" {
                        self.showToast("被控端未安装虚拟音频设备（BlackHole / VB-Cable），无法回传麦克风")
                    } else {
                        let detail = reason.map { " (\($0))" } ?? ""
                        self.showToast("被控端麦克风不可用\(detail)")
                    }
                } else if enabled {
                    if self.micCapturer.start() {
                        self.micEnabled = true
                        self.toolbarPanel?.updateState(micOn: true)
                        let target = device.map { " → \($0)" } ?? ""
                        self.showToast("麦克风回传已开启\(target)")
                    } else {
                        self.micEnabled = false
                        self.toolbarPanel?.updateState(micOn: false)
                        self.connection.sendSetMicEnabled(false)
                        self.showToast("本机麦克风启动失败（请检查麦克风权限）")
                    }
                } else {
                    self.micCapturer.stop()
                    self.micEnabled = false
                    self.toolbarPanel?.updateState(micOn: false)
                }
            }
        }

        connection.onCursorShape = { _ in
            // Intentionally keep the local controller's native cursor instead of
            // replacing it with the remote machine's cursor shape.
        }

        connection.onClipboardReceived = { [weak self] data in
            self?.clipboardSync.applyRemoteClipboard(data)
        }

        connection.onClipboardFilesFromTarget = { [weak self] files in
            DispatchQueue.main.async {
                self?.handleRemoteClipboardFiles(files)
            }
        }

        connection.onStatsUpdated = { [weak self] stats in
            DispatchQueue.main.async {
                guard let self else { return }
                let size = self.rendererView.videoSize
                self.statsHudView.update(
                    stats: stats,
                    width: Int(size.width),
                    height: Int(size.height),
                    isRelay: self.connectParams.mode == .relay
                )
                self.toolbarPanel?.updateState(isTrueLan: self.connection.isTrueLan)
            }
        }

        connection.onDirListing = { [weak self] path, entries in
            DispatchQueue.main.async {
                self?.fileTransferSheet?.handleDirListing(path: path, entries: entries)
            }
        }

        connection.onFileTransferProgress = { [weak self] progress in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileTransferSheet?.updateTransferProgress(progress)
                if progress.done {
                    if let err = progress.error {
                        self.showToast("文件传输失败: \(progress.name) (\(err))")
                    } else if progress.direction == .upload {
                        self.showToast("已上传: \(progress.name)")
                    } else {
                        self.showToast("已下载: \(progress.name)")
                    }
                }
            }
        }

        connection.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.showToast(message)
                if self.connection.state != .streaming && self.connection.state != .reconnecting {
                    self.disconnectAndClose(errorMessage: message)
                }
            }
        }

        connection.onDisconnected = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                self.disconnectAndClose(errorMessage: reason.isEmpty ? nil : reason)
            }
        }
    }

    private func applyQualityPreset(_ preset: QualityPreset, sendToServer: Bool, showToastMessage: Bool) {
        let isTrueLan = connection.isTrueLan
        settings.qualityPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: Self.qualityPresetDefaultsKey)

        var shouldSendChroma = false
        switch preset {
        case .auto:
            settings.fps = 60
            settings.autoFps = true
            settings.bitrateBps = isTrueLan ? 15_000_000 : 6_000_000
            settings.autoBitrate = true
            settings.sharpness = .low
        case .smooth:
            settings.fps = 60
            settings.autoFps = false
            settings.bitrateBps = isTrueLan ? 10_000_000 : 6_000_000
            settings.autoBitrate = false
            settings.chromaMode = .yuv420
            settings.sharpness = .low
            shouldSendChroma = true
        case .hd:
            settings.fps = 60
            settings.autoFps = false
            settings.bitrateBps = isTrueLan ? 25_000_000 : 15_000_000
            settings.autoBitrate = false
            settings.chromaMode = .yuv420
            settings.sharpness = .medium
            shouldSendChroma = true
        case .original:
            settings.fps = 60
            settings.autoFps = false
            settings.bitrateBps = isTrueLan ? 40_000_000 : 30_000_000
            settings.autoBitrate = false
            settings.chromaMode = .yuv444
            settings.sharpness = .medium
            shouldSendChroma = true
        }

        DeviceStore.shared.saveSettings(settings)
        rendererView.sharpness = settings.sharpness
        rendererView.targetFPS = settings.fps
        if sendToServer {
            connection.sendFps(settings.fps, auto: settings.autoFps)
            connection.sendBitrate(settings.bitrateBps, auto: settings.autoBitrate)
            if shouldSendChroma {
                connection.sendChroma(settings.chromaMode)
            }
        }
        toolbarPanel?.updateState(
            qualityPreset: preset,
            sharpness: settings.sharpness,
            chromaMode: settings.chromaMode,
            fps: settings.fps,
            fpsAuto: settings.autoFps,
            bitrateBps: settings.bitrateBps,
            bitrateAuto: settings.autoBitrate,
            isTrueLan: isTrueLan
        )
        if showToastMessage {
            showToast("画质预设: \(preset.displayName)")
        }
    }

    private func wireToolbar(_ toolbar: FloatingToolbarPanel) {
        toolbar.onQualityPresetChanged = { [weak self] preset in
            self?.applyQualityPreset(preset, sendToServer: true, showToastMessage: true)
        }

        toolbar.onSharpnessChanged = { [weak self] level in
            guard let self else { return }
            self.settings.sharpness = level
            DeviceStore.shared.saveSettings(self.settings)
            self.rendererView.sharpness = level
            self.toolbarPanel?.updateState(sharpness: level)
            self.showToast("锐化强度: \(level.displayName)")
        }

        toolbar.onChromaToggled = { [weak self] mode in
            guard let self else { return }
            self.settings.chromaMode = mode
            DeviceStore.shared.saveSettings(self.settings)
            self.connection.sendChroma(mode)
            self.toolbarPanel?.updateState(chromaMode: mode)
        }

        toolbar.onHdrToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.hdrEnabled = enabled
            if !enabled {
                self.settings.toneMapEnabled = false
                self.rendererView.toneMap = false
            }
            DeviceStore.shared.saveSettings(self.settings)
            self.connection.sendHdr(enabled: enabled)
            self.toolbarPanel?.updateState(hdrEnabled: enabled, toneMapEnabled: self.settings.toneMapEnabled)
        }

        toolbar.onToneMapToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.toneMapEnabled = enabled
            DeviceStore.shared.saveSettings(self.settings)
            self.rendererView.toneMap = enabled
            self.toolbarPanel?.updateState(toneMapEnabled: enabled)
            self.showToast(enabled ? "已开启 SDR 色调映射" : "已关闭 SDR 色调映射")
        }

        toolbar.onLowLatencyToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.lowLatencyEnabled = enabled
            DeviceStore.shared.saveSettings(self.settings)
            self.connection.sendLowLatency(enabled)
            self.toolbarPanel?.updateState(lowLatencyEnabled: enabled)
            self.showToast(enabled ? "已开启零缓冲极速模式" : "已关闭零缓冲极速模式")
        }

        toolbar.onToggleStatsHud = { [weak self] visible in
            guard let self else { return }
            self.statsHudVisible = visible
            self.statsHudView.isHidden = !visible
            self.toolbarPanel?.updateState(statsHudVisible: visible)
            self.showToast(visible ? "已显示性能浮窗" : "已隐藏性能浮窗")
        }

        toolbar.onMatchLocalHiDPIToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.matchLocalHiDPI = enabled
            self.settings.resolutionTier = enabled ? .match : .native
            UserDefaults.standard.set(enabled, forKey: Self.matchLocalHiDPIDefaultsKey)
            DeviceStore.shared.saveSettings(self.settings)
            self.toolbarPanel?.updateState(resolution: self.settings.resolutionTier, matchLocalHiDPI: enabled)
            if enabled {
                self.hasSentMatchLocalHiDPI = true
                self.sendMatchLocalHiDPI()
                self.showToast("匹配本机 HiDPI 已开启")
            } else {
                self.connection.sendResolution(tier: .native)
                self.showToast("匹配本机 HiDPI 已关闭")
            }
        }

        toolbar.onResolutionChanged = { [weak self] tier in
            guard let self else { return }
            self.settings.resolutionTier = tier
            self.settings.matchLocalHiDPI = (tier == .match)
            UserDefaults.standard.set(self.settings.matchLocalHiDPI, forKey: Self.matchLocalHiDPIDefaultsKey)
            DeviceStore.shared.saveSettings(self.settings)
            self.toolbarPanel?.updateState(resolution: tier, matchLocalHiDPI: self.settings.matchLocalHiDPI)
            if tier == .match {
                self.hasSentMatchLocalHiDPI = true
                self.sendMatchLocalHiDPI()
            } else {
                self.connection.sendResolution(tier: tier)
            }
            self.showToast("分辨率: \(tier.displayName)")
        }

        toolbar.onScaleModeChanged = { [weak self] mode in
            guard let self else { return }
            self.settings.scaleMode = mode
            DeviceStore.shared.saveSettings(self.settings)
            self.rendererView.scaleMode = mode
            self.toolbarPanel?.updateState(scaleMode: mode)
        }

        toolbar.onFpsChanged = { [weak self] fps, auto in
            guard let self else { return }
            self.settings.fps = fps
            self.settings.autoFps = auto
            DeviceStore.shared.saveSettings(self.settings)
            self.rendererView.targetFPS = fps
            self.connection.sendFps(fps, auto: auto)
            self.toolbarPanel?.updateState(fps: fps, fpsAuto: auto)
        }

        toolbar.onBitrateChanged = { [weak self] bitrate, auto in
            guard let self else { return }
            self.settings.bitrateBps = bitrate
            self.settings.autoBitrate = auto
            DeviceStore.shared.saveSettings(self.settings)
            self.connection.sendBitrate(bitrate, auto: auto)
            self.toolbarPanel?.updateState(bitrateBps: bitrate, bitrateAuto: auto)
        }

        toolbar.onCodecChanged = { [weak self] codec in
            guard let self else { return }
            self.manualCodecSelected = true
            self.settings.preferredCodec = codec
            DeviceStore.shared.saveSettings(self.settings)
            self.connection.sendSetCodec(codec)
            self.toolbarPanel?.updateState(codec: codec)
        }

        toolbar.onForceKeyframe = { [weak self] in
            self?.connection.sendRequestKeyframe()
            self?.showToast("已请求刷新关键帧")
        }

        toolbar.onCtrlAltDel = { [weak self] in
            self?.connection.sendCtrlAltDel()
            self?.showToast("已发送 Ctrl + Alt + Delete")
        }

        toolbar.onLockScreen = { [weak self] in
            self?.connection.sendPowerAction("lock")
            self?.showToast("已锁定远端屏幕")
        }

        toolbar.onPowerAction = { [weak self] action in
            self?.handlePowerAction(action)
        }

        toolbar.onDisplaySelected = { [weak self] displayId in
            guard let self else { return }
            self.activeDisplayId = displayId
            self.toolbarPanel?.updateDisplays(self.displays, activeId: displayId)
            self.connection.sendSetDisplay(displayId)
            let name = self.displays.first(where: { $0.id == displayId })?.name ?? "#\(displayId)"
            self.showToast("切换显示器: \(name)")
        }

        toolbar.onCycleDisplay = { [weak self] in
            guard let self, self.displays.count > 1 else { return }
            let idx = self.displays.firstIndex(where: { $0.id == self.activeDisplayId }) ?? 0
            let next = self.displays[(idx + 1) % self.displays.count]
            self.activeDisplayId = next.id
            self.toolbarPanel?.updateDisplays(self.displays, activeId: next.id)
            self.connection.sendSetDisplay(next.id)
            self.showToast("切换显示器: \(next.name)")
        }

        toolbar.onVirtualDisplayToggled = { [weak self] enabled in
            guard let self else { return }
            self.connection.sendVirtualDisplay(action: enabled ? "create" : "destroy")
        }

        toolbar.onAudioToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.audioEnabled = enabled
            DeviceStore.shared.saveSettings(self.settings)
            self.audioPlayer.isEnabled = enabled
            if enabled {
                self.audioPlayer.start()
            } else {
                self.audioPlayer.stop()
            }
            self.connection.sendSetAudio(enabled: enabled)
            self.toolbarPanel?.updateState(audioOn: enabled)
        }

        toolbar.onVolumeChanged = { [weak self] vol in
            guard let self else { return }
            self.settings.audioVolume = vol
            DeviceStore.shared.saveSettings(self.settings)
            self.audioPlayer.volume = vol
            self.toolbarPanel?.updateState(volume: vol)
        }

        toolbar.onMicToggled = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.connection.sendSetMicEnabled(true)
            } else {
                self.micCapturer.stop()
                self.micEnabled = false
                self.toolbarPanel?.updateState(micOn: false)
                self.connection.sendSetMicEnabled(false)
                self.showToast("已关闭麦克风回传")
            }
        }

        toolbar.onPrivacyToggled = { [weak self] enabled in
            guard let self else { return }
            self.privacyEnabled = enabled
            self.connection.sendSetPrivacyScreen(enabled: enabled)
            self.toolbarPanel?.updateState(privacyOn: enabled)
            self.showToast(enabled ? "已开启远端隐私屏" : "已关闭远端隐私屏")
        }

        toolbar.onPointerLockToggled = { [weak self] in
            self?.inputManager.togglePointerLock()
        }

        toolbar.onMacWinSwapToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.macWinKeySwap = enabled
            DeviceStore.shared.saveSettings(self.settings)
            self.inputManager.swapMacToWinModifiers = enabled
            self.toolbarPanel?.updateState(macWinSwapOn: enabled)
            self.showToast(enabled ? "已开启 ⌘ ↔ Ctrl 键位互换" : "已关闭 ⌘ ↔ Ctrl 键位互换")
        }

        toolbar.onClipboardSyncToggled = { [weak self] enabled in
            guard let self else { return }
            self.settings.clipboardSyncEnabled = enabled
            DeviceStore.shared.saveSettings(self.settings)
            self.clipboardSync.isEnabled = enabled
            self.connection.setClipboardSyncEnabled(enabled)
            self.connection.setReverseClipboardActive(enabled)
            if enabled {
                self.clipboardSync.syncNow()
            }
            self.toolbarPanel?.updateState(clipboardSyncOn: enabled)
            self.showToast(enabled ? "已开启剪贴板同步" : "已关闭剪贴板同步")
        }

        toolbar.onFileTransferRequested = { [weak self] in
            self?.presentFileTransferSheet()
        }

        toolbar.onFullscreenToggled = { [weak self] in
            self?.toggleFullscreen()
        }

        toolbar.onDisconnectRequested = { [weak self] in
            self?.disconnectAndClose(errorMessage: nil)
        }
    }

    private func applyInitialSettings() {
        audioPlayer.isEnabled = settings.audioEnabled
        audioPlayer.volume = settings.audioVolume
        clipboardSync.isEnabled = settings.clipboardSyncEnabled
        rendererView.sharpness = settings.sharpness
        rendererView.toneMap = settings.toneMapEnabled
        toolbarPanel?.updateState(
            qualityPreset: settings.qualityPreset,
            sharpness: settings.sharpness,
            chromaMode: settings.chromaMode,
            hdrEnabled: settings.hdrEnabled,
            toneMapEnabled: settings.toneMapEnabled,
            lowLatencyEnabled: settings.lowLatencyEnabled,
            resolution: settings.resolutionTier,
            scaleMode: settings.scaleMode,
            fps: settings.fps,
            fpsAuto: settings.autoFps,
            bitrateBps: settings.bitrateBps,
            bitrateAuto: settings.autoBitrate,
            codec: settings.preferredCodec,
            audioOn: settings.audioEnabled,
            volume: settings.audioVolume,
            privacyOn: false,
            pointerLocked: false,
            macWinSwapOn: settings.macWinKeySwap,
            clipboardSyncOn: settings.clipboardSyncEnabled,
            isFullscreen: false,
            statsHudVisible: statsHudVisible,
            matchLocalHiDPI: settings.matchLocalHiDPI
        )
    }

    private func sendMatchLocalHiDPI() {
        let screen = window?.screen ?? NSScreen.main
        let logicalWidth = Int((screen?.frame.width ?? window?.frame.width ?? rendererView.bounds.width).rounded())
        let logicalHeight = Int((screen?.frame.height ?? window?.frame.height ?? rendererView.bounds.height).rounded())
        let scale = max(2.0, Double(screen?.backingScaleFactor ?? window?.backingScaleFactor ?? 2.0))
        connection.sendResolution(
            tier: .match,
            width: max(640, logicalWidth),
            height: max(480, logicalHeight),
            scale: scale
        )
    }

    // MARK: - Overlay, Toast & File Transfer

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connecting:
            hasSentCodecCaps = false
            hasSentMatchLocalHiDPI = false
            showOverlay(title: "正在连接…", subtitle: "建立 WebSocket 加密通道")
        case .authenticating:
            showOverlay(title: "正在认证…", subtitle: "验证访问凭据与密钥协商")
        case .reconnecting:
            hasSentCodecCaps = false
            micCapturer.stop()
            micEnabled = false
            toolbarPanel?.updateState(micOn: false)
            showOverlay(title: "连接中断，正在重连…", subtitle: "自动重试中")
        case .streaming:
            hideOverlay()
        case .disconnected, .idle, .error:
            micCapturer.stop()
            micEnabled = false
            toolbarPanel?.updateState(micOn: false)
            break
        }
    }

    private func showOverlay(title: String, subtitle: String) {
        overlayTitle.stringValue = title
        overlaySubtitle.stringValue = subtitle
        overlayCard.isHidden = false
        overlaySpinner.startAnimation(nil)
    }

    private func hideOverlay() {
        overlaySpinner.stopAnimation(nil)
        overlayCard.isHidden = true
    }

    public func showToast(_ message: String) {
        toastTimer?.invalidate()
        toastLabel.stringValue = message
        toastCard.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastCard.animator().alphaValue = 1.0
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.toastCard.animator().alphaValue = 0.0
            }, completionHandler: {
                self.toastCard.isHidden = true
            })
        }
    }

    private func presentFileTransferSheet() {
        guard let win = window else { return }
        if fileTransferSheet == nil {
            let sheet = FileTransferSheetController(connection: connection)
            sheet.onUploadError = { [weak self] msg in
                self?.showToast(msg)
            }
            fileTransferSheet = sheet
        }
        guard let sheetWin = fileTransferSheet?.window else { return }
        if sheetWin.sheetParent == nil {
            win.beginSheet(sheetWin) { [weak self] _ in
                self?.window?.makeFirstResponder(self?.rendererView)
            }
            fileTransferSheet?.requestInitialDirectory()
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = FileTransferClient.enumerateUploadItems(from: urls)
        guard !items.isEmpty else {
            showToast("未找到可上传的文件")
            return
        }
        let hasDir = urls.contains { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if hasDir {
            showToast("开始递归上传 \(urls.count) 项（共 \(items.count) 个文件）…")
        } else {
            showToast("开始上传 \(items.count) 个文件…")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.connection.uploadItems(at: urls, destDir: nil, resume: true)
            } catch {
                await MainActor.run {
                    self.showToast("上传失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Bidirectional Clipboard File Sync (Item 4)

    private func syncLocalClipboardFilesToRemote(urls: [URL]) {
        guard settings.clipboardSyncEnabled, connection.isConnected, !urls.isEmpty else { return }
        let items = FileTransferClient.enumerateUploadItems(from: urls)
        guard !items.isEmpty else { return }

        var totalBytes: Int64 = 0
        let fm = FileManager.default
        for item in items {
            if let attrs = try? fm.attributesOfItem(atPath: item.url.path),
               let sz = (attrs[.size] as? NSNumber)?.int64Value {
                totalBytes += sz
            }
        }
        if totalBytes > Self.maxLocalClipboardUploadBytes {
            showToast("剪贴板文件超过 100MB，请通过文件管理器上传")
            return
        }

        clipboardFileSyncTask?.cancel()
        clipboardFileSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let remotePaths = try await self.connection.uploadItems(
                    at: urls,
                    destDir: nil,
                    resume: true,
                    purpose: "clipboard",
                    waitForDone: true
                )
                guard !Task.isCancelled, !remotePaths.isEmpty else { return }
                self.connection.sendClipboardSetFiles(paths: remotePaths)
                await MainActor.run {
                    self.showToast("已同步剪贴板文件到远端 (\(remotePaths.count) 个)")
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.showToast("剪贴板文件同步失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleRemoteClipboardFiles(_ files: [RemoteClipboardFile]) {
        guard settings.clipboardSyncEnabled, !files.isEmpty else { return }
        let hasDir = files.contains { $0.isDir }
        let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.size) }

        if hasDir || totalBytes > Self.maxRemoteClipboardDownloadBytes {
            showToast("远端剪贴板包含文件夹或超过 50MB，请通过文件管理器拉取")
            return
        }

        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let clipboardDir = cacheBase.appendingPathComponent("Remoter/Clipboard", isDirectory: true)

        remoteClipboardDownloadTask?.cancel()
        remoteClipboardDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: clipboardDir, withIntermediateDirectories: true)
                var downloadedURLs: [URL] = []
                for file in files {
                    try Task.checkCancellation()
                    let safeName = FileTransferClient.sanitizeFileName(file.name.isEmpty ? FileTransferClient.extractRemoteFileName(file.path) : file.name)
                    let targetURL = clipboardDir.appendingPathComponent(safeName)
                    let savedPath = try await self.connection.downloadFile(
                        remotePath: file.path,
                        to: targetURL,
                        overwriteExisting: true
                    )
                    downloadedURLs.append(URL(fileURLWithPath: savedPath))
                }
                guard !Task.isCancelled, !downloadedURLs.isEmpty else { return }
                await MainActor.run {
                    self.clipboardSync.applyRemoteClipboardFiles(downloadedURLs)
                    self.showToast("已同步远端剪贴板文件 (\(downloadedURLs.count) 个)，可直接 Cmd+V 粘贴")
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.showToast("拉取远端剪贴板文件失败: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func cancelOverlayTapped() {
        disconnectAndClose(errorMessage: nil)
    }

    private func handlePowerAction(_ action: String) {
        switch action {
        case "lock":
            connection.sendPowerAction("lock")
            showToast("已锁定远端屏幕")
        case "sleep":
            confirmPowerAction(
                title: "休眠远程电脑",
                message: "确定让远程电脑进入休眠吗？",
                confirmTitle: "休眠"
            ) { [weak self] in
                self?.connection.sendPowerAction("sleep")
                self?.showToast("已发送远端休眠指令")
            }
        case "restart":
            confirmPowerAction(
                title: "重启远程电脑",
                message: "确定重启远程电脑吗？未保存的数据可能会丢失。",
                confirmTitle: "重启"
            ) { [weak self] in
                self?.connection.sendPowerAction("restart")
                self?.showToast("已发送远端重启指令")
            }
        default:
            break
        }
    }

    private func confirmPowerAction(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        if let win = window {
            alert.beginSheetModal(for: win) { response in
                if response == .alertFirstButtonReturn {
                    onConfirm()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    // MARK: - Teardown & NSWindowDelegate

    private func teardown() {
        guard !isTornDown else { return }
        isTornDown = true

        toastTimer?.invalidate()
        toastTimer = nil
        clipboardFileSyncTask?.cancel()
        clipboardFileSyncTask = nil
        remoteClipboardDownloadTask?.cancel()
        remoteClipboardDownloadTask = nil

        rendererView.cancelImeComposition()
        inputManager.setPointerLocked(false)
        inputManager.releaseAllKeys()
        inputManager.resetCursor()

        clipboardSync.stop()
        micCapturer.stop()
        micEnabled = false
        audioPlayer.stop()
        videoDecoder.invalidate()
        connection.disconnect()

        if let toolbar = toolbarPanel {
            window?.removeChildWindow(toolbar)
            toolbar.orderOut(nil)
            toolbar.close()
            toolbarPanel = nil
        }
        fileTransferSheet?.window?.close()
        fileTransferSheet = nil
    }

    public func windowWillClose(_ notification: Notification) {
        teardown()
        let err = closeErrorMessage
        closeErrorMessage = nil
        onClosed?(err)
    }

    public func windowDidMove(_ notification: Notification) {
        toolbarPanel?.updatePosition()
    }

    public func windowDidResize(_ notification: Notification) {
        toolbarPanel?.updatePosition()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if clipboardSync.isEnabled {
            clipboardSync.syncNow()
            connection.setReverseClipboardActive(true)
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        rendererView.cancelImeComposition()
        inputManager.releaseAllKeys()
        if inputManager.isPointerLocked {
            inputManager.setPointerLocked(false)
        }
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        toolbarPanel?.orderOut(nil)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        toolbarPanel?.updatePosition()
        toolbarPanel?.orderFront(nil)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        toolbarPanel?.updateState(isFullscreen: true)
        reattachToolbar()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        toolbarPanel?.updateState(isFullscreen: false)
        reattachToolbar()
    }

    /// 进入/退出全屏会换 Space，子窗口关系会被系统丢掉，悬浮栏随之消失；切换完成后重新挂载并置前。
    private func reattachToolbar() {
        guard let win = window, let toolbar = toolbarPanel else { return }
        if toolbar.parent !== win {
            win.addChildWindow(toolbar, ordered: .above)
        }
        toolbar.updatePosition()
        toolbar.orderFront(nil)
    }
}

// MARK: - RemoteCanvasContainerView

private final class RemoteCanvasContainerView: NSView {
    weak var inputManager: InputManager?
    var onFilesDropped: (([URL]) -> Void)?
    private var isDragHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let inputManager, inputManager.shouldCaptureKeyEquivalent(event) {
            inputManager.handleKeyDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        inputManager?.handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        inputManager?.handleKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputManager?.handleFlagsChanged(event)
    }

    // MARK: - Drag & Drop Local Files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return [] }
        setDragHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDragHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragHighlight(false)
        guard let urls = extractFileURLs(from: sender), !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    private func hasFileURLs(in info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func extractFileURLs(from info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private func setDragHighlight(_ highlighted: Bool) {
        guard isDragHighlighted != highlighted else { return }
        isDragHighlighted = highlighted
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = highlighted ? Theme.accent.cgColor : NSColor.clear.cgColor
        }
        layer?.borderWidth = highlighted ? 3 : 0
    }
}
