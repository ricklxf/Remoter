import Foundation
import Carbon.HIToolbox

/// For as long as any client is connected, forces this Mac's system input
/// source to plain English (ABC layout) and keeps re-asserting it — tools
/// like KeyboardHolder switch the input source per frontmost app, which
/// silently changes what a given keystroke actually produces out from under
/// Remoter. This is unrelated to InputLocker (which blocks a *local physical
/// user* — not the concern here, since nobody's expected to be at the
/// machine while it's being controlled): begin()/end() are driven by
/// session lifetime (Session.swift's auth handlers, main.swift's
/// removeSession), not by the input lock toggle. Safe to force regardless:
/// Remoter's own text injection never depends on the target's current input
/// source (ASCII keys are raw keycodes, CJK text is written directly via
/// keyboardSetUnicodeString bypassing system IME entirely), so this costs
/// nothing on Remoter's side. Restores whatever was active before the first
/// session connected once the last one disconnects.
final class InputSourceForcer {
    static let shared = InputSourceForcer()

    private let forcedSourceID = "com.apple.keylayout.ABC"
    private var savedSourceID: String?
    private var observer: NSObjectProtocol?
    private var active = false

    private init() {}

    // TIS (Text Input Source) calls are only safe on the main thread —
    // confirmed via a real crash (dispatch_assert_queue_fail inside
    // TSMGetInputSourceProperty) with begin() called directly from
    // Session.routeMessage, which runs on whichever NIO event loop thread
    // is servicing that connection, not main. Every caller (Session.swift's
    // auth handlers, main.swift's removeSession/SIGTERM handler) is off the
    // main thread at least some of the time, so the dispatch belongs here,
    // not at each call site.
    func begin() {
        DispatchQueue.main.async { [self] in
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
    }

    func end() {
        DispatchQueue.main.async { [self] in
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
    }

    private func forceEnglish() {
        guard active else { return }
        guard let target = Self.findASCIISource(preferredID: forcedSourceID) else {
            ConnectionLogger.shared.logStep(sessionId: "input", step: "input_source_force_failed",
                detail: "\(forcedSourceID) and ASCII-capable fallback not installed")
            return
        }
        guard Self.currentInputSourceID() != target.id else { return }
        let status = TISSelectInputSource(target.source)
        ConnectionLogger.shared.logStep(sessionId: "input", step: "input_source_force",
            detail: "source=\(target.id) status=\(status)")
    }

    private static func findASCIISource(preferredID: String) -> (source: TISInputSource, id: String)? {
        if let preferred = findInputSource(id: preferredID) {
            return (preferred, preferredID)
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           let id = inputSourceID(ascii) {
            return (ascii, id)
        }
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsASCIICapable: kCFBooleanTrue as Any,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
            kTISPropertyInputSourceIsEnabled: kCFBooleanTrue as Any,
        ]
        if let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] {
            for source in list {
                if let id = inputSourceID(source) {
                    return (source, id)
                }
            }
        }
        return nil
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
