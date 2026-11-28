import AppKit

/// Dark visual design system for Remoter-MacClient.
/// Matches `#121419` background, `#1A1E26` surface, `#252A36` elevated, and `#0FB8AB` teal accent.
public enum Theme {
    // MARK: - Color Palette
    // Follows the system appearance like the Web client (`system` theme): dark values are the
    // original palette, light values are the Web light theme (global.css `:root`).

    private static func dyn(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }
    }

    public static let background      = dyn(dark: 0x121419, light: 0xF0F4F8)
    public static let surface         = dyn(dark: 0x1A1E26, light: 0xFFFFFF)
    public static let elevated        = dyn(dark: 0x252A36, light: 0xF1F5F9)
    public static let inputBackground = dyn(dark: 0x151820, light: 0xF1F5F9)
    public static let hover           = dyn(dark: 0x2C3240, light: 0xE2E8F0)
    public static let border          = dyn(dark: 0x2E3545, light: 0xD1D5DB)
    public static let accent          = dyn(dark: 0x0FB8AB, light: 0x0D9488)
    public static let accentHover     = dyn(dark: 0x0DA094, light: 0x0F766E)
    public static let accentDim       = dyn(dark: 0x0FB8AB, light: 0x0D9488, darkAlpha: 0.18, lightAlpha: 0.14)
    /// Text on top of a solid accent fill (primary buttons).
    public static let onAccent        = dyn(dark: 0x0A1014, light: 0xFFFFFF)
    public static let danger          = dyn(dark: 0xE04848, light: 0xDC2626)
    public static let dangerHover     = dyn(dark: 0xC63838, light: 0xB91C1C)
    public static let dangerBackground = dyn(dark: 0xE04848, light: 0xFEF2F2, darkAlpha: 0.12, lightAlpha: 1)
    public static let dangerBorder    = dyn(dark: 0xE04848, light: 0xFECACA, darkAlpha: 0.45, lightAlpha: 1)
    public static let warning         = dyn(dark: 0xF5B441, light: 0xD97706)
    public static let warningDim      = dyn(dark: 0xF5B441, light: 0xD97706, darkAlpha: 0.18, lightAlpha: 0.14)
    public static let info            = dyn(dark: 0x38BDF8, light: 0x0284C7)
    public static let infoDim         = dyn(dark: 0x38BDF8, light: 0x0284C7, darkAlpha: 0.18, lightAlpha: 0.14)
    public static let textPrimary     = dyn(dark: 0xE8ECF2, light: 0x1A1A2E)
    public static let textMuted       = dyn(dark: 0x8C95A6, light: 0x64748B)
    /// Letterbox area around the remote picture (Web `--canvas-surround`).
    public static let videoBackground = dyn(dark: 0x0B0D11, light: 0xE6F7F5)
    public static let hudBackground   = dyn(dark: 0x161A22, light: 0xFFFFFF, darkAlpha: 0.92, lightAlpha: 0.92)

    /// Only for overlays drawn on top of the video (stats HUD), which stay dark in both themes.
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
        let field: NSTextField = secure ? ThemedSecureTextField() : ThemedTextField()
        // Stops macOS from offering its "密码…" AutoFill popup over our own PIN / password fields.
        field.contentType = secure ? .oneTimeCode : nil
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = font(size: 13)
        field.textColor = textPrimary
        field.backgroundColor = inputBackground
        field.drawsBackground = true
        field.isBezeled = false
        field.focusRingType = .exterior
        field.wantsLayer = true
        applyFieldColors(field)
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

    public static func makeCard(background: NSColor = surface, cornerRadius: CGFloat = 10) -> ThemedLayerView {
        let view = ThemedLayerView()
        view.fillColor = background
        view.strokeColor = border
        view.strokeWidth = 1
        view.cornerRadius = cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    public static func makeSeparator(vertical: Bool = false) -> NSView {
        let view = ThemedLayerView()
        view.fillColor = border
        view.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return view
    }

    static func applyFieldColors(_ field: NSTextField) {
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            field.layer?.backgroundColor = inputBackground.cgColor
            field.layer?.borderColor = border.cgColor
        }
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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyStyleResolved() }
    }

    private func applyStyleResolved() {
        let bg: NSColor
        let fg: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat
        let radius: CGFloat

        switch buttonStyle {
        case .primary:
            bg = isHovered ? Theme.accentHover : Theme.accent
            fg = Theme.onAccent
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

    private var backgroundFill: NSColor

    public init(text: String, background: NSColor, foreground: NSColor) {
        self.label = Theme.makeLabel(text, size: 10.5, weight: .semibold, color: foreground)
        self.backgroundFill = background
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        applyBackground()

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
        backgroundFill = background
        applyBackground()
        label.textColor = foreground
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundFill.cgColor
        }
    }
}

// MARK: - ThemedLayerView

/// Layer-backed view whose fill / stroke colors are dynamic `NSColor`s: `cgColor` snapshots go stale
/// when the system switches between light and dark, so they are re-resolved on every appearance change.
public final class ThemedLayerView: NSView {
    public var fillColor: NSColor? { didSet { refresh() } }
    public var strokeColor: NSColor? { didSet { refresh() } }
    public var strokeWidth: CGFloat = 0 { didSet { refresh() } }
    public var cornerRadius: CGFloat = 0 { didSet { refresh() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor?.cgColor
            layer.borderColor = strokeColor?.cgColor
        }
        layer.borderWidth = strokeWidth
        layer.cornerRadius = cornerRadius
    }
}

// MARK: - Themed text fields

/// Single-line text rect inset horizontally and centered vertically inside the field
/// (AppKit draws text at the top of a tall field by default).
private func centeredTextRect(_ base: NSRect, cell: NSCell, bounds: NSRect) -> NSRect {
    var r = base
    let textHeight = cell.cellSize(forBounds: bounds).height
    r.origin.x += 8
    r.size.width = max(0, r.size.width - 16)
    r.origin.y += max(0, (r.size.height - textHeight) / 2)
    r.size.height = min(r.size.height, textHeight)
    return r
}

final class CenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(super.titleRect(forBounds: rect), cell: self, bounds: rect)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

final class CenteredSecureTextFieldCell: NSSecureTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(super.titleRect(forBounds: rect), cell: self, bounds: rect)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

final class ThemedTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredTextFieldCell.self }
        set {}
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Theme.applyFieldColors(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Theme.applyFieldColors(self)
    }
}

final class ThemedSecureTextField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { CenteredSecureTextFieldCell.self }
        set {}
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Theme.applyFieldColors(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Theme.applyFieldColors(self)
    }
}
