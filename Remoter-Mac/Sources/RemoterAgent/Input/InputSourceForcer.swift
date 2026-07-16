import Foundation
import Carbon.HIToolbox

/// While the input lock (InputLocker) is on, forces this Mac's system input
/// source to plain English (ABC layout) and keeps re-asserting it — tools
/// like KeyboardHolder switch the input source per frontmost app, which
/// fights with whoever's remote-controlling this machine. Safe to force:
/// Remoter's own text injection never depends on the target's current input
/// source (ASCII keys are raw keycodes, CJK text is written directly via
/// keyboardSetUnicodeString bypassing system IME entirely), so locking this
/// to English costs nothing on Remoter's side. Restores whatever was active
/// before locking once the lock is released.
final class InputSourceForcer {
    static let shared = InputSourceForcer()

    private let forcedSourceID = "com.apple.keylayout.ABC"
    private var savedSourceID: String?
    private var observer: NSObjectProtocol?
    private var active = false

    private init() {}

    func begin() {
        guard !active else { return }
        active = true
        savedSourceID = Self.currentInputSourceID()
        forceEnglish()
        // Re-assert immediately after anything switches the input source
        // while locked (e.g. KeyboardHolder reacting to a focus change).
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.forceEnglish()
        }
    }

    func end() {
        guard active else { return }
        active = false
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        if let saved = savedSourceID, let source = Self.findInputSource(id: saved) {
            TISSelectInputSource(source)
        }
        savedSourceID = nil
    }

    private func forceEnglish() {
        guard active else { return }
        guard Self.currentInputSourceID() != forcedSourceID else { return }
        guard let source = Self.findInputSource(id: forcedSourceID) else {
            ConnectionLogger.shared.logStep(sessionId: "input", step: "input_source_force_failed",
                detail: "\(forcedSourceID) not installed")
            return
        }
        let status = TISSelectInputSource(source)
        ConnectionLogger.shared.logStep(sessionId: "input", step: "input_source_force",
            detail: "status=\(status)")
    }

    private static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return inputSourceID(source)
    }

    private static func findInputSource(id: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first { inputSourceID($0) == id }
    }

    private static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
