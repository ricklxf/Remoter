import AppKit

/// UU-style translucent black bottom-right performance HUD overlay (matching UURemote's `NetDetailView`).
/// Plain `NSView` added directly above the remote canvas (NOT an `NSPanel`), 100% click-through via
/// `hitTest(_:) -> nil`, and immune to Light Mode or bright remote desktop bleed via `wantsUpdateLayer`.
public final class StatsHudOverlayView: NSView {
    private static let hudFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    private static let backgroundColor = NSColor.black.withAlphaComponent(0.40)
    private static let defaultTextColor = NSColor.white.withAlphaComponent(0.82)
    private static let brightTextColor = NSColor.white.withAlphaComponent(0.85)
    private static let decodeTextColor = NSColor.white.withAlphaComponent(0.72)
    private static let mutedTextColor = NSColor.white.withAlphaComponent(0.55)
    private static let separatorColor = NSColor.white.withAlphaComponent(0.45)
    private static let goodColor = NSColor(hex: 0x34D399)
    private static let warnColor = NSColor(hex: 0xF59E0B)
    private static let dangerColor = NSColor(hex: 0xEF4444)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 2.5
        return style
    }()

    private let label: NSTextField

    public override init(frame frameRect: NSRect) {
        self.label = NSTextField(wrappingLabelWithString: "")
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
        layer.cornerRadius = 4
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
        label.textColor = Self.defaultTextColor
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
            widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        renderPlaceholder()
        needsDisplay = true
    }

    // MARK: - Telemetry Rendering

    public func update(stats: ClientStats) {
        let attr = NSMutableAttributedString()

        // Line 1: <transport> · <codec> <HW/SW>
        let transport = stats.transport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transport.isEmpty {
            appendSegment(transport, color: Self.defaultTextColor, to: attr)
            appendSegment(" · ", color: Self.separatorColor, to: attr)
        }
        appendSegment("\(stats.codec.badgeText) ", color: Self.defaultTextColor, to: attr)
        let decodeTag = stats.isHardwareDecoded ? "HW" : "SW"
        let decodeColor = stats.isHardwareDecoded ? Self.goodColor : Self.warnColor
        appendSegment(decodeTag, color: decodeColor, to: attr)

        // Line 2: <fps> fps
        appendNewline(to: attr)
        let fpsRounded = Int(stats.fps.rounded())
        let fpsColor: NSColor
        if stats.fps <= 0 {
            fpsColor = Self.mutedTextColor
        } else if stats.fps < 15 {
            fpsColor = Self.dangerColor
        } else if stats.fps < 25 {
            fpsColor = Self.warnColor
        } else {
            fpsColor = Self.brightTextColor
        }
        appendSegment("\(fpsRounded) fps", color: fpsColor, to: attr)

        // Line 3: <mbps> Mbps
        appendNewline(to: attr)
        let mbps = Double(stats.bitrateKbps) / 1000.0
        appendSegment(String(format: "%.1f Mbps", mbps), color: Self.defaultTextColor, to: attr)

        // Line 4: <rtt> ms (UU thresholds: <50 green, 50-99 white, 100-150 amber, >150 red)
        appendNewline(to: attr)
        if stats.rttMs >= 0 {
            let rttColor: NSColor
            if stats.rttMs < 50 {
                rttColor = Self.goodColor
            } else if stats.rttMs < 100 {
                rttColor = Self.brightTextColor
            } else if stats.rttMs <= 150 {
                rttColor = Self.warnColor
            } else {
                rttColor = Self.dangerColor
            }
            appendSegment("\(stats.rttMs) ms", color: rttColor, to: attr)
        } else {
            appendSegment("-- ms", color: Self.mutedTextColor, to: attr)
        }

        // Line 5 (optional): dec <decodeMs> ms
        if stats.decodeMs > 0 {
            appendNewline(to: attr)
            appendSegment(String(format: "dec %.1f ms", Double(stats.decodeMs)), color: Self.decodeTextColor, to: attr)
        }

        label.attributedStringValue = attr
    }

    private func renderPlaceholder() {
        let attr = NSMutableAttributedString()
        appendSegment("-- fps\n0.0 Mbps\n-- ms", color: Self.mutedTextColor, to: attr)
        label.attributedStringValue = attr
    }

    private func appendSegment(_ text: String, color: NSColor, to target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: text, attributes: [
            .font: Self.hudFont,
            .foregroundColor: color,
            .paragraphStyle: Self.paragraphStyle,
        ]))
    }

    private func appendNewline(to target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: "\n", attributes: [
            .font: Self.hudFont,
            .foregroundColor: Self.defaultTextColor,
            .paragraphStyle: Self.paragraphStyle,
        ]))
    }
}
