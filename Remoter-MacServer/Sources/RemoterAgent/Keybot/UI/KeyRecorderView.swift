import SwiftUI
import AppKit

struct KeyRecorderView: NSViewRepresentable {
    @Binding var trigger: KeyTrigger

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let v = KeyRecorderNSView()
        v.onCapture = { t in trigger = t }
        return v
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.setIdleDisplay(
            trigger.keyCode == 0 && trigger.modifiers.isEmpty ? nil : trigger.displayString
        )
    }
}

// MARK: -

final class KeyRecorderNSView: NSView {
    var onCapture: ((KeyTrigger) -> Void)?
    private(set) var isRecording = false

    private let label = NSTextField(labelWithString: "Click to record…")
    private let clearBtn: NSButton = {
        let b = NSButton(title: "✕", target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11)
        b.contentTintColor = .tertiaryLabelColor
        return b
    }()
    private var localMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        applyIdleStyle()

        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.target = self
        clearBtn.action = #selector(clearTrigger)
        addSubview(clearBtn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -4),

            clearBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clearBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 18),

            heightAnchor.constraint(equalToConstant: 36),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(startRecording))
        addGestureRecognizer(click)
    }

    // MARK: - State

    func setIdleDisplay(_ text: String?) {
        guard !isRecording else { return }
        if let t = text {
            label.stringValue = t
            label.textColor = .labelColor
            clearBtn.isHidden = false
        } else {
            label.stringValue = "Click to record…"
            label.textColor = .placeholderTextColor
            clearBtn.isHidden = true
        }
        applyIdleStyle()
    }

    private func applyIdleStyle() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.shadowOpacity = 0
    }

    private func applyRecordingStyle() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
    }

    // MARK: - Recording

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        KeybotEventTap.shared.isCapturingKey = true
        label.stringValue = "Press a key combination…"
        label.textColor = .secondaryLabelColor
        clearBtn.isHidden = true
        applyRecordingStyle()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureEvent(event)
            return nil
        }
    }

    private func captureEvent(_ event: NSEvent) {
        stopRecording()

        var mods: [ModifierKey] = []
        let f = event.modifierFlags
        if f.contains(.control) { mods.append(.control) }
        if f.contains(.option)  { mods.append(.option) }
        if f.contains(.shift)   { mods.append(.shift) }
        if f.contains(.command) { mods.append(.command) }

        let t = KeyTrigger(keyCode: Int(event.keyCode), modifiers: mods)
        label.stringValue = t.displayString
        label.textColor = .labelColor
        clearBtn.isHidden = false
        onCapture?(t)
    }

    private func stopRecording() {
        isRecording = false
        KeybotEventTap.shared.isCapturingKey = false
        applyIdleStyle()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    @objc private func clearTrigger() {
        stopRecording()
        let empty = KeyTrigger(keyCode: 0, modifiers: [])
        label.stringValue = "Click to record…"
        label.textColor = .placeholderTextColor
        clearBtn.isHidden = true
        onCapture?(empty)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }
}
