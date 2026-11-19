import AppKit

/// Dark visual design system for Remoter-MacClient.
/// Matches `#121419` background, `#1A1E26` surface, `#252A36` elevated, and `#0FB8AB` teal accent.
public enum Theme {
    // MARK: - Color Palette

    public static let background      = NSColor(hex: 0x121419)
    public static let surface         = NSColor(hex: 0x1A1E26)
    public static let elevated        = NSColor(hex: 0x252A36)
    public static let inputBackground = NSColor(hex: 0x151820)
    public static let hover           = NSColor(hex: 0x2C3240)
    public static let border          = NSColor(hex: 0x2E3545)
    public static let accent          = NSColor(hex: 0x0FB8AB)
    public static let accentHover     = NSColor(hex: 0x0DA094)
    public static let accentDim       = NSColor(hex: 0x0FB8AB, alpha: 0.18)
    public static let danger          = NSColor(hex: 0xE04848)
    public static let dangerHover     = NSColor(hex: 0xC63838)
    public static let warning         = NSColor(hex: 0xF5B441)
    public static let warningDim      = NSColor(hex: 0xF5B441, alpha: 0.18)
    public static let info            = NSColor(hex: 0x38BDF8)
    public static let infoDim         = NSColor(hex: 0x38BDF8, alpha: 0.18)
    public static let textPrimary     = NSColor(hex: 0xE8ECF2)
    public static let textMuted       = NSColor(hex: 0x8C95A6)
    public static let videoBackground = NSColor(hex: 0x0B0D11)
    public static let hudBackground   = NSColor(hex: 0x161A22, alpha: 0.92)

    public static var darkAppearance: NSAppearance? {
        NSAppearance(named: .darkAqua)
    }

    // MARK: - Typography

    public static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    public static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Factory Helpers

    public static func makeLabel(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = textPrimary,
        monospaced: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = monospaced ? monoFont(size: size, weight: weight) : font(size: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    public static func makeTextField(
        placeholder: String = "",
        text: String = "",
        secure: Bool = false
    ) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = font(size: 13)
        field.textColor = textPrimary
        field.backgroundColor = inputBackground
        field.drawsBackground = true
        field.isBezeled = false
        field.focusRingType = .exterior
        field.wantsLayer = true
        field.layer?.backgroundColor = inputBackground.cgColor
        field.layer?.borderColor = border.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 7
        field.translatesAutoresizingMaskIntoConstraints = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }
        return field
    }

    public enum ButtonStyle {
        case primary
        case secondary
        case danger
        case toolbar
        case toolbarActive
        case ghost
    }

    public static func makeButton(
        title: String,
        style: ButtonStyle = .secondary,
        fontSize: CGFloat = 13,
        weight: NSFont.Weight = .medium,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) -> ThemedButton {
        let button = ThemedButton(title: title, style: style, fontSize: fontSize, weight: weight)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    public static func makeBadge(
        text: String,
        background: NSColor = accentDim,
        foreground: NSColor = accent
    ) -> BadgeView {
        let badge = BadgeView(text: text, background: background, foreground: foreground)
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    public static func makeCard(background: NSColor = surface, cornerRadius: CGFloat = 10) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.layer?.borderColor = border.cgColor
        view.layer?.borderWidth = 1
        view.layer?.cornerRadius = cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    public static func makeSeparator(vertical: Bool = false) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = border.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return view
    }

    public static func makeCheckbox(
        title: String,
        checked: Bool = false,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: target, action: action)
        checkbox.state = checked ? .on : .off
        checkbox.font = font(size: 12.5)
        checkbox.contentTintColor = accent
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        return checkbox
    }

    public static func osSymbolName(for serverOs: String?) -> String {
        let lower = (serverOs ?? "").lowercased()
        if lower.contains("mac") || lower.contains("darwin") || lower.contains("osx") {
            return "desktopcomputer"
        } else if lower.contains("win") {
            return "pc"
        } else if lower.contains("linux") {
            return "terminal"
        }
        return "display"
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    public static func formatSpeed(_ bps: Double) -> String {
        if bps <= 0 { return "" }
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        let kb = bps / 1024.0
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024.0)
    }
}

// MARK: - NSColor Hex Helper

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - ThemedButton

public final class ThemedButton: NSButton {
    public var buttonStyle: Theme.ButtonStyle {
        didSet { applyStyle() }
    }
    private var fontSize: CGFloat
    private var fontWeight: NSFont.Weight
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    public init(
        title: String,
        style: Theme.ButtonStyle = .secondary,
        fontSize: CGFloat = 13,
        weight: NSFont.Weight = .medium
    ) {
        self.buttonStyle = style
        self.fontSize = fontSize
        self.fontWeight = weight
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.focusRingType = .none
        self.setButtonType(.momentaryChange)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var title: String {
        didSet { applyStyle() }
    }

    public override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
            applyStyle()
        }
    }

    public override func updateTrackingAreas() {
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

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        applyStyle()
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        applyStyle()
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func applyStyle() {
        let bg: NSColor
        let fg: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat
        let radius: CGFloat

        switch buttonStyle {
        case .primary:
            bg = isHovered ? Theme.accentHover : Theme.accent
            fg = NSColor(hex: 0x0A1014)
            borderColor = .clear
            borderWidth = 0
            radius = 8
        case .secondary:
            bg = isHovered ? Theme.hover : Theme.elevated
            fg = Theme.textPrimary
            borderColor = Theme.border
            borderWidth = 1
            radius = 7
        case .danger:
            bg = isHovered ? Theme.dangerHover : Theme.danger
            fg = .white
            borderColor = .clear
            borderWidth = 0
            radius = 7
        case .toolbar:
            bg = isHovered ? Theme.hover : Theme.elevated.withAlphaComponent(0.85)
            fg = Theme.textPrimary
            borderColor = Theme.border
            borderWidth = 1
            radius = 6
        case .toolbarActive:
            bg = isHovered ? Theme.accent.withAlphaComponent(0.28) : Theme.accentDim
            fg = Theme.accent
            borderColor = Theme.accent.withAlphaComponent(0.7)
            borderWidth = 1
            radius = 6
        case .ghost:
            bg = isHovered ? Theme.hover.withAlphaComponent(0.6) : .clear
            fg = Theme.textMuted
            borderColor = .clear
            borderWidth = 0
            radius = 6
        }

        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = borderWidth
        layer?.cornerRadius = radius

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.font(size: fontSize, weight: fontWeight),
                .foregroundColor: fg,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

// MARK: - BadgeView

public final class BadgeView: NSView {
    private let label: NSTextField

    public var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    public init(text: String, background: NSColor, foreground: NSColor) {
        self.label = Theme.makeLabel(text, size: 10.5, weight: .semibold, color: foreground)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.cornerRadius = 4

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateColors(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        label.textColor = foreground
    }
}
