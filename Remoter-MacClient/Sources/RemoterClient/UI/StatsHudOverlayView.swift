import AppKit

/// UU Remote 1:1 bottom-right performance HUD overlay (matching UURemote's `NetDetailView`,
/// Web `StatsHUD.tsx`, and Windows `StatsHudOverlay.cs`).
/// 8 uniform light-white regular-weight monospace lines, 35% black rounded background,
/// borderless, 100% click-through via `hitTest(_:) -> nil`.
public final class StatsHudOverlayView: NSView {
    private static let hudFont = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    private static let backgroundColor = NSColor.black.withAlphaComponent(0.35)
    private static let textColor = NSColor.white.withAlphaComponent(0.88)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 2.5
        return style
    }()

    private let label: NSTextField
    private let sessionStartTime = Date()
    private var lastStats: ClientStats?
    private var streamWidth: Int = 0
    private var streamHeight: Int = 0
    private var isRelay: Bool = false
    private var packetLossPct: Double = 0.0
    private var durationTimer: Timer?

    public override init(frame frameRect: NSRect) {
        self.label = NSTextField(wrappingLabelWithString: "")
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Click-through & Layer Backing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public override var wantsUpdateLayer: Bool {
        true
    }

    public override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = Self.backgroundColor.cgColor
        layer.cornerRadius = 6
        layer.borderWidth = 0
        layer.borderColor = nil
        layer.masksToBounds = true
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = Theme.darkAppearance
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.usesSingleLineMode = false
        label.font = Self.hudFont
        label.textColor = Self.textColor
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 108),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        renderLines()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderLines()
        }
        needsDisplay = true
    }

    // MARK: - Telemetry Rendering

    public func update(
        stats: ClientStats,
        width: Int = 0,
        height: Int = 0,
        isRelay: Bool = false,
        packetLossPct: Double = 0.0
    ) {
        self.lastStats = stats
        if width > 0 { self.streamWidth = width }
        if height > 0 { self.streamHeight = height }
        self.isRelay = isRelay
        self.packetLossPct = packetLossPct
        renderLines()
    }

    private func renderLines() {
        let elapsed = max(0, Int(Date().timeIntervalSince(sessionStartTime)))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        let durationLine = String(format: "%02d:%02d:%02d", h, m, s)

        let proto = (lastStats?.transport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "TCP"
        let mode = isRelay ? "relay" : "direct"
        let transportLine = "\(proto) \(mode)"

        let fpsLine: String
        let bitrateLine: String
        let rttLine: String
        let frmLine: String

        if let stats = lastStats {
            fpsLine = "\(Int(stats.fps.rounded())) fps"
            if stats.bitrateKbps < 1000 {
                bitrateLine = String(format: "%.1f Kbps", Double(max(0, stats.bitrateKbps)))
            } else {
                bitrateLine = String(format: "%.1f Mbps", Double(stats.bitrateKbps) / 1000.0)
            }
            rttLine = stats.rttMs >= 0 ? "\(stats.rttMs) ms" : "-- ms"
            let frmMs = max(0, stats.encodeMs) + max(0, stats.decodeMs)
            frmLine = "\(frmMs) ms frm."
        } else {
            fpsLine = "-- fps"
            bitrateLine = "0.0 Kbps"
            rttLine = "-- ms"
            frmLine = "0 ms frm."
        }

        let lossLine = String(format: "%.1f%% loss", max(0.0, packetLossPct))
        let resLine = Self.formatResolutionTier(width: streamWidth, height: streamHeight)

        let text = [
            durationLine,
            transportLine,
            fpsLine,
            bitrateLine,
            rttLine,
            frmLine,
            lossLine,
            resLine,
        ].joined(separator: "\n")

        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Self.hudFont,
            .foregroundColor: Self.textColor,
            .paragraphStyle: Self.paragraphStyle,
        ])
    }

    private static func formatResolutionTier(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "--" }
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        if longEdge >= 3840 || shortEdge >= 2160 { return "4K" }
        if longEdge >= 2560 || shortEdge >= 1440 { return "2K" }
        if shortEdge >= 1080 { return "1080P" }
        if shortEdge >= 720 { return "720P" }
        return "\(shortEdge)P"
    }
}
