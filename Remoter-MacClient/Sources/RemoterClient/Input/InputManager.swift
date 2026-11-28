import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Handles low-latency macOS mouse, precise trackpad scroll, keyboard, pointer lock (game mouse),
/// and remote cursor shape rendering for a remote desktop session.
public final class InputManager {

    // MARK: - Public Properties

    public weak var connection: RemoterConnection?
    public weak var rendererView: MetalRendererView?

    /// When `true`, swaps macOS Command ↔ Control so Cmd+C/V/A/Z maps to Ctrl+C/V/A/Z on Windows hosts.
    public var swapMacToWinModifiers: Bool = true

    /// When `true`, all local input events are suppressed (read-only viewing mode).
    public var isViewOnly: Bool = false {
        didSet {
            if isViewOnly {
                if isPointerLocked {
                    setPointerLocked(false)
                }
                releaseAllKeys()
            }
        }
    }

    public private(set) var isPointerLocked: Bool = false
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onPasteShortcut: (() -> Void)?

    // MARK: - Private State

    private var pressedKeyCodes: Set<String> = []
    private var pressedMouseButtons: Set<String> = []
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    // Pointer lock virtual cursor state
    private var lockedNormX: Double = 0.5
    private var lockedNormY: Double = 0.5
    private var isCursorHiddenByLock: Bool = false

    // Remote cursor state
    private var currentRemoteCursor: NSCursor?
    private var isCursorHiddenByRemote: Bool = false

    // MARK: - Lifecycle

    public init(connection: RemoterConnection? = nil, rendererView: MetalRendererView? = nil) {
        self.connection = connection
        self.rendererView = rendererView
    }

    deinit {
        if isPointerLocked {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if isCursorHiddenByLock {
            NSCursor.unhide()
            isCursorHiddenByLock = false
        }
        if isCursorHiddenByRemote {
            NSCursor.unhide()
            isCursorHiddenByRemote = false
        }
    }

    // MARK: - Button Name Helper

    public static func otherButtonName(_ buttonNumber: Int) -> String {
        switch buttonNumber {
        case 2:  return "middle"
        case 3:  return "back"
        case 4:  return "forward"
        default: return "middle"
        }
    }

    // MARK: - Pointer Lock / Game Mouse

    /// Enables or disables macOS pointer lock (`CGAssociateMouseAndMouseCursorPosition(0)` + `NSCursor.hide()`).
    public func setPointerLocked(_ locked: Bool) {
        guard locked != isPointerLocked else { return }

        if locked {
            guard !isViewOnly else { return }
            isPointerLocked = true
            CGAssociateMouseAndMouseCursorPosition(0)
            if !isCursorHiddenByLock {
                NSCursor.hide()
                isCursorHiddenByLock = true
            }
        } else {
            isPointerLocked = false
            CGAssociateMouseAndMouseCursorPosition(1)
            if isCursorHiddenByLock {
                NSCursor.unhide()
                isCursorHiddenByLock = false
            }
        }

        onPointerLockChanged?(isPointerLocked)
    }

    public func togglePointerLock() {
        setPointerLocked(!isPointerLocked)
    }

    // MARK: - Mouse Events

    public func handleMouseMoved(_ event: NSEvent) {
        guard !isViewOnly, let connection else { return }
        guard let (nx, ny) = resolveCoordinates(for: event) else { return }
        connection.sendMouseMove(x: nx, y: ny, dragging: nil)
    }

    public func handleMouseDragged(_ event: NSEvent, button: String) {
        guard !isViewOnly, let connection else { return }
        guard let (nx, ny) = resolveCoordinates(for: event) else { return }
        connection.sendMouseMove(x: nx, y: ny, dragging: button)
    }

    public func handleMouseDown(_ event: NSEvent, button: String) {
        guard !isViewOnly, let connection else { return }
        guard let (nx, ny) = resolveCoordinates(for: event) else { return }

        pressedMouseButtons.insert(button)
        connection.sendMouseButton(button: button, down: true, x: nx, y: ny)

        if event.clickCount == 2 {
            connection.sendMouseDoubleClick(button: button, x: nx, y: ny)
        }
    }

    public func handleMouseUp(_ event: NSEvent, button: String) {
        guard !isViewOnly, let connection else { return }
        guard let (nx, ny) = resolveCoordinates(for: event) else { return }

        pressedMouseButtons.remove(button)
        connection.sendMouseButton(button: button, down: false, x: nx, y: ny)
    }

    /// Handles both precise macOS trackpad scrolling (`hasPreciseScrollingDeltas` with `phase` & `momentumPhase`)
    /// and discrete scroll-wheel notches using UU-style delta scaling.
    public func handleScrollWheel(_ event: NSEvent) {
        guard !isViewOnly, let connection else { return }

        let isPrecise = event.hasPreciseScrollingDeltas
        let phase = Int(event.phase.rawValue)
        let momentumPhase = Int(event.momentumPhase.rawValue)

        if isPrecise {
            let px = Int((event.scrollingDeltaX * 2.0).rounded())
            let py = Int((event.scrollingDeltaY * 2.0).rounded())
            // Keep dx/dy populated for hosts that ignore px/py while preserving pixel precision
            let dx = Int(event.scrollingDeltaX.rounded())
            let dy = Int(event.scrollingDeltaY.rounded())
            guard px != 0 || py != 0 || phase != 0 || momentumPhase != 0 else { return }

            connection.sendMouseScroll(
                dx: dx,
                dy: dy,
                px: px,
                py: py,
                isPrecise: true,
                phase: phase,
                momentumPhase: momentumPhase
            )
        } else {
            // Discrete mouse wheel. `scrollingDelta*` is already in lines (~1 per notch), which is what the
            // host expects for dx/dy ("notches"; it injects notches * 100px). Sending *120 here (the Windows
            // unit) made the host scroll 12000px per notch, i.e. straight to the end of the page.
            let lineX = event.scrollingDeltaX
            let lineY = event.scrollingDeltaY
            func notches(_ v: CGFloat) -> Int { v == 0 ? 0 : (v > 0 ? max(1, Int(v.rounded())) : min(-1, Int(v.rounded()))) }
            let dx = notches(lineX)
            let dy = notches(lineY)
            guard dx != 0 || dy != 0 else { return }

            connection.sendMouseScroll(
                dx: dx,
                dy: dy,
                px: Int((lineX * 100.0).rounded()),
                py: Int((lineY * 100.0).rounded()),
                isPrecise: false,
                phase: nil,
                momentumPhase: nil
            )
        }
    }

    // MARK: - Keyboard Events

    public func handleKeyDown(_ event: NSEvent) {
        // Ctrl + Opt + Enter toggles Pointer Lock even if currently locked
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Int(event.keyCode) == kVK_Return,
           flags.contains(.control),
           flags.contains(.option),
           !flags.contains(.command),
           !flags.contains(.shift) {
            togglePointerLock()
            return
        }

        guard !isViewOnly, let connection else { return }
        if Int(event.keyCode) == kVK_ANSI_V && (flags.contains(.command) || flags.contains(.control)) {
            onPasteShortcut?()
        }
        guard let code = KeyCodeMapper.mapKeyCode(event.keyCode, swapMacToWinModifiers: swapMacToWinModifiers) else {
            return
        }

        pressedKeyCodes.insert(code)
        let mods = KeyCodeMapper.collectModifiers(from: event.modifierFlags, swapMacToWinModifiers: swapMacToWinModifiers)
        connection.sendKey(code: code, down: true, modifiers: mods)
    }

    public func handleKeyUp(_ event: NSEvent) {
        guard !isViewOnly, let connection else { return }
        guard let code = KeyCodeMapper.mapKeyCode(event.keyCode, swapMacToWinModifiers: swapMacToWinModifiers) else {
            return
        }

        pressedKeyCodes.remove(code)
        let mods = KeyCodeMapper.collectModifiers(from: event.modifierFlags, swapMacToWinModifiers: swapMacToWinModifiers)
        connection.sendKey(code: code, down: false, modifiers: mods)
    }

    public func handleFlagsChanged(_ event: NSEvent) {
        guard !isViewOnly, let connection else { return }
        guard let code = KeyCodeMapper.mapKeyCode(event.keyCode, swapMacToWinModifiers: swapMacToWinModifiers) else {
            return
        }

        let newFlags = event.modifierFlags.intersection([.shift, .control, .option, .command, .capsLock])
        let isDown: Bool

        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift:
            isDown = newFlags.contains(.shift)
        case kVK_Control, kVK_RightControl:
            isDown = newFlags.contains(.control)
        case kVK_Option, kVK_RightOption:
            isDown = newFlags.contains(.option)
        case kVK_Command, kVK_RightCommand:
            isDown = newFlags.contains(.command)
        case kVK_CapsLock:
            isDown = newFlags.contains(.capsLock)
        default:
            isDown = newFlags.rawValue > lastModifierFlags.rawValue
        }

        lastModifierFlags = newFlags

        let mods = KeyCodeMapper.collectModifiers(from: event.modifierFlags, swapMacToWinModifiers: swapMacToWinModifiers)

        // macOS AppKit suppresses `keyUp` for character keys pressed while Command is held
        // (forwarded via `performKeyEquivalent`). Release any lingering non-modifier keys
        // before releasing Command so the remote host never stays stuck with shortcut keys held.
        let isCommandKey = (Int(event.keyCode) == kVK_Command || Int(event.keyCode) == kVK_RightCommand)
        if isCommandKey && !isDown {
            let modifierWireCodes: Set<String> = [
                "MetaLeft", "MetaRight", "ControlLeft", "ControlRight",
                "AltLeft", "AltRight", "ShiftLeft", "ShiftRight", "CapsLock"
            ]
            for held in pressedKeyCodes where !modifierWireCodes.contains(held) {
                pressedKeyCodes.remove(held)
                connection.sendKey(code: held, down: false, modifiers: mods)
            }
        }

        if isDown {
            pressedKeyCodes.insert(code)
        } else {
            pressedKeyCodes.remove(code)
        }

        connection.sendKey(code: code, down: isDown, modifiers: mods)
    }

    /// Determines whether `performKeyEquivalent` should intercept a Cmd-key shortcut and forward it
    /// to the remote host rather than triggering a local macOS menu item.
    public func shouldCaptureKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !isViewOnly else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Always let Cmd+Q (quit) and Cmd+M (minimize) through to macOS unless pointer-locked
        if !isPointerLocked && flags == .command {
            let key = Int(event.keyCode)
            if key == kVK_ANSI_Q || key == kVK_ANSI_M {
                return false
            }
        }
        return flags.contains(.command) || flags.contains(.control)
    }

    /// Releases all currently held keys and mouse buttons on the remote host (e.g., on resign-key or disconnect).
    public func releaseAllKeys() {
        if let connection {
            for code in pressedKeyCodes {
                connection.sendKey(code: code, down: false, modifiers: [])
            }
            for button in pressedMouseButtons {
                connection.sendMouseButton(button: button, down: false, x: lockedNormX, y: lockedNormY)
            }
        }
        pressedKeyCodes.removeAll()
        pressedMouseButtons.removeAll()
        lastModifierFlags = []
    }

    // MARK: - Remote Cursor Shape

    /// Applies a remote PNG cursor + hotspot received from the host, or hides/restores cleanly.
    public func applyRemoteCursor(_ info: CursorShapeInfo) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if !info.isVisible {
                if !self.isCursorHiddenByRemote {
                    NSCursor.hide()
                    self.isCursorHiddenByRemote = true
                }
                return
            }

            if self.isCursorHiddenByRemote {
                NSCursor.unhide()
                self.isCursorHiddenByRemote = false
            }

            let pngBytes: Data
            if !info.pngData.isEmpty {
                pngBytes = info.pngData
            } else if !info.pngBase64.isEmpty, let decoded = Data(base64Encoded: info.pngBase64) {
                pngBytes = decoded
            } else {
                return
            }

            guard let image = NSImage(data: pngBytes) else { return }
            if info.width > 0, info.height > 0 {
                image.size = NSSize(width: info.width, height: info.height)
            }

            let hotSpot = NSPoint(
                x: max(0, min(CGFloat(info.hotX), image.size.width)),
                y: max(0, min(CGFloat(info.hotY), image.size.height))
            )

            let cursor = NSCursor(image: image, hotSpot: hotSpot)
            self.currentRemoteCursor = cursor
            if !self.isPointerLocked {
                cursor.set()
            }
        }
    }

    /// Restores the default system arrow cursor and un-hides if previously hidden.
    public func resetCursor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isCursorHiddenByRemote {
                NSCursor.unhide()
                self.isCursorHiddenByRemote = false
            }
            self.currentRemoteCursor = nil
            if !self.isPointerLocked {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - Coordinate Resolution

    private func resolveCoordinates(for event: NSEvent) -> (Double, Double)? {
        if isPointerLocked {
            let refSize = rendererView?.videoSize ?? CGSize(width: 1920, height: 1080)
            let denomW = refSize.width > 0 ? Double(refSize.width) : 1920.0
            let denomH = refSize.height > 0 ? Double(refSize.height) : 1080.0

            lockedNormX = min(1.0, max(0.0, lockedNormX + Double(event.deltaX) / denomW))
            lockedNormY = min(1.0, max(0.0, lockedNormY + Double(event.deltaY) / denomH))
            return (lockedNormX, lockedNormY)
        }

        guard let rendererView else { return nil }
        guard let coords = rendererView.normalizeWindowPoint(event.locationInWindow) else { return nil }
        lockedNormX = coords.0
        lockedNormY = coords.1
        return coords
    }
}
