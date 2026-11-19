import AppKit

/// UU-style translucent black bottom-right performance HUD overlay (inspired by UURemote's `NetDetailView`).
/// Plain `NSView` added directly above the remote canvas (NOT an `NSPanel`), 100% click-through via
/// `hitTest(_:) -> nil`, and immune to Light Mode or bright remote desktop bleed via `wantsUpdateLayer`.
public final class StatsHudOverlayView: NSView {
    private static let hudFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let backgroundColor = NSColor.black.withAlphaComponent(0.62)
    private static let borderColor = NSColor.white.withAlphaComponent(0.12)
    private static let normalTextColor = NSColor.white.withAlphaComponent(0.90)
    private static let mutedTextColor = NSColor.white.withAlphaComponent(0.55)
    private static let separatorColor = NSColor.white.withAlphaComponent(0.40)
    private static let goodColor = NSColor(hex: 0x34D399)

    private let label: NSTextField

    public override init(frame frameRect: NSRect) {
        self.label = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        layer.borderWidth = 1
        layer.borderColor = Self.borderColor.cgColor
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
        label.font = Self.hudFont
        label.textColor = Self.normalTextColor
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        renderPlaceholder()
        needsDisplay = true
    }

    // MARK: - Telemetry Rendering

    public func update(stats: ClientStats) {
        let attr = NSMutableAttributedString()

        // 1. FPS
        let fpsRounded = Int(stats.fps.rounded())
        let fpsColor: NSColor
        if stats.fps <= 0 {
            fpsColor = Self.mutedTextColor
        } else if stats.fps < 15 {
            fpsColor = Theme.danger
        } else if stats.fps < 25 {
            fpsColor = Theme.warning
        } else {
            fpsColor = Self.normalTextColor
        }
        appendSegment("\(fpsRounded) fps", color: fpsColor, to: attr)

        // 2. Bitrate
        appendSeparator(to: attr)
        let mbps = Double(stats.bitrateKbps) / 1000.0
        appendSegment(String(format: "%.1f Mbps", mbps), color: Self.normalTextColor, to: attr)

        // 3. RTT (UU thresholds: <50 green/teal, 50-99 white, 100-150 amber, >150 red)
        appendSeparator(to: attr)
        if stats.rttMs >= 0 {
            let rttColor: NSColor
            if stats.rttMs < 50 {
                rttColor = Self.goodColor
            } else if stats.rttMs < 100 {
                rttColor = Self.normalTextColor
            } else if stats.rttMs <= 150 {
                rttColor = Theme.warning
            } else {
                rttColor = Theme.danger
            }
            appendSegment("\(stats.rttMs) ms", color: rttColor, to: attr)
        } else {
            appendSegment("-- ms", color: Self.mutedTextColor, to: attr)
        }

        // 4. Codec
        appendSeparator(to: attr)
        appendSegment(stats.codec.badgeText, color: Self.normalTextColor, to: attr)

        // 5. HW / SW decode tag
        appendSeparator(to: attr)
        let decodeTag = stats.isHardwareDecoded ? "HW" : "SW"
        let decodeColor = stats.isHardwareDecoded ? Self.goodColor : Theme.warning
        appendSegment(decodeTag, color: decodeColor, to: attr)

        // 6. Optional decode time when available
        if stats.decodeMs > 0 {
            appendSeparator(to: attr)
            appendSegment("dec \(stats.decodeMs)ms", color: Self.normalTextColor, to: attr)
        }

        label.attributedStringValue = attr
    }

    private func renderPlaceholder() {
        let attr = NSMutableAttributedString()
        appendSegment("-- fps", color: Self.mutedTextColor, to: attr)
        appendSeparator(to: attr)
        appendSegment("0.0 Mbps", color: Self.mutedTextColor, to: attr)
        appendSeparator(to: attr)
        appendSegment("-- ms", color: Self.mutedTextColor, to: attr)
        label.attributedStringValue = attr
    }

    private func appendSegment(_ text: String, color: NSColor, to target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: text, attributes: [
            .font: Self.hudFont,
            .foregroundColor: color,
        ]))
    }

    private func appendSeparator(to target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: " · ", attributes: [
            .font: Self.hudFont,
            .foregroundColor: Self.separatorColor,
        ]))
    }
}
