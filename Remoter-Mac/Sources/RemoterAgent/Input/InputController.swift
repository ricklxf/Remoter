import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

final class InputController {
    var screenWidth: Int
    var screenHeight: Int
    // Global-coordinate origin of the captured display: client coordinates
    // are normalized [0,1] within *that display*, but CGEvent's
    // mouseCursorPosition is in the global desktop space where a secondary
    // display starts at its CGDisplayBounds origin, not (0,0).
    var originX: Double
    var originY: Double
    private var loggedAccessibility = false
    private var pressedKeys = Set<CGKeyCode>()

    // CGEvent.post() is a synchronous IPC call to WindowServer, made
    // directly on whatever thread handles the incoming WS message — if it's
    // ever slow, that thread (and thus reading the next message) is
    // blocked. Capture-side frame throughput has been repeatedly observed
    // to collapse the instant input starts, recovering ~60-90s after it
    // stops, independent of network/decode (confirmed via zero backpressure
    // drops and zero decode-overload signals in the same window) — this
    // measures the one remaining unverified link in that chain: whether the
    // post() call itself is what's slow.
    private var postCount = 0
    private var postSlowCount = 0     // > 2ms
    private var postMaxMs: Double = 0
    private var postStatTick = Date()

    // Continuous scroll lifecycle tracking (macOS trackpad simulation)
    private var isScrollingContinuous = false
    private var scrollEndWorkItem: DispatchWorkItem?
    private let scrollLock = NSLock()
    private var lastMousePoint: CGPoint = .zero
    private lazy var smoothScroller = SmoothScrollEngine(controller: self)

    init(screenWidth: Int, screenHeight: Int, originX: Double = 0, originY: Double = 0) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.originX = originX
        self.originY = originY
    }

    private func timedPost(_ e: CGEvent, tap: CGEventTapLocation) {
        // Tag every event we inject so InputLocker's tap can tell "Remoter
        // injected this" apart from "real hardware produced this" and let
        // ours through even while local physical input is locked out.
        e.setIntegerValueField(.eventSourceUserData, value: InputLocker.injectedTag)
        let t0 = CFAbsoluteTimeGetCurrent()
        e.post(tap: tap)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        postCount += 1
        if ms > 2 { postSlowCount += 1 }
        if ms > postMaxMs { postMaxMs = ms }
        let now = Date()
        if now.timeIntervalSince(postStatTick) >= 5 {
            ConnectionLogger.shared.logStep(sessionId: "input", step: "post_5s",
                detail: "count=\(postCount) slow=\(postSlowCount) maxMs=\(String(format: "%.1f", postMaxMs))")
            postCount = 0
            postSlowCount = 0
            postMaxMs = 0
            postStatTick = now
        }
    }

    // dragging: nil while no button is held (plain hover), or "left"/"right"/
    // "middle" while one is — macOS distinguishes .mouseMoved from
    // .leftMouseDragged etc. as separate event TYPES, not a move event plus
    // a button-state flag. Controls that select-by-drag (text fields, the
    // browser's address bar, sliders) specifically listen for the dragged
    // type, so without this they never see a drag — only disconnected
    // moves + a separate down/up, which looks like a click, not a drag.
    func mouseMove(x: Double, y: Double, dragging: String? = nil) {
        if !loggedAccessibility {
            loggedAccessibility = true
            NSLog("[Input] accessibility trusted=%d", AXIsProcessTrusted() ? 1 : 0)
        }
        let pt = cgPoint(x: x, y: y)
        scrollLock.lock()
        lastMousePoint = pt
        scrollLock.unlock()
        let src = CGEventSource(stateID: .hidSystemState)
        let (type, btn): (CGEventType, CGMouseButton) = switch dragging {
        case "right":  (.rightMouseDragged, .right)
        case "middle": (.otherMouseDragged, .center)
        case "left":   (.leftMouseDragged,  .left)
        default:       (.mouseMoved,        .left)
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: btn) else {
            print("[Input] mouseMove: CGEvent creation failed")
            return
        }
        timedPost(e, tap: .cgSessionEventTap)
    }

    func mouseButton(button: String, down: Bool, x: Double, y: Double) {
        let pt = cgPoint(x: x, y: y)
        scrollLock.lock()
        lastMousePoint = pt
        scrollLock.unlock()
        let (type, btn): (CGEventType, CGMouseButton) = switch (button, down) {
        case ("right", true):   (.rightMouseDown, .right)
        case ("right", false):  (.rightMouseUp,   .right)
        case ("middle", true):  (.otherMouseDown, .center)
        case ("middle", false): (.otherMouseUp,   .center)
        case (_, true):         (.leftMouseDown,  .left)
        default:                (.leftMouseUp,    .left)
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: btn) else { return }
        // Without an explicit click count, some apps' tracking areas/gesture
        // recognizers ignore the synthetic down/up as not a "real" click.
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        timedPost(e, tap: .cgSessionEventTap)
    }

    func mouseDoubleClick(button: String, x: Double, y: Double) {
        let pt  = cgPoint(x: x, y: y)
        scrollLock.lock()
        lastMousePoint = pt
        scrollLock.unlock()
        let src = CGEventSource(stateID: .hidSystemState)
        let type: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
        let btn: CGMouseButton = button == "right" ? .right : .left
        guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: btn) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 2)
        timedPost(e, tap: .cgSessionEventTap)
        guard let eu = CGEvent(mouseEventSource: src,
                               mouseType: button == "right" ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: pt, mouseButton: btn) else { return }
        eu.setIntegerValueField(.mouseEventClickState, value: 2)
        timedPost(eu, tap: .cgSessionEventTap)
    }

    func injectScrollStep(stepX: Int32, stepY: Int32, phase: CGScrollPhase) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                              wheelCount: 2, wheel1: stepY, wheel2: stepX, wheel3: 0) else { return }
        scrollLock.lock()
        let loc = lastMousePoint
        scrollLock.unlock()
        if loc != .zero {
            e.location = loc
        }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(stepY))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(stepX))
        timedPost(e, tap: .cgSessionEventTap)
    }

    /// px/py (pixels) when the client sends them, else dx/dy (wheel notches,
    /// older clients).
    /// isPrecise indicates continuous high-frequency touchpad input vs mechanical wheel.
    func mouseScroll(dx: Int, dy: Int, px: Int? = nil, py: Int? = nil, isPrecise: Bool? = nil) {
        let rawPx = px ?? (dx * 100)
        let rawPy = py ?? (dy * 100)
        guard rawPx != 0 || rawPy != 0 else { return }

        // Determine whether this is a continuous touchpad gesture or discrete mechanical notch
        let continuous = isPrecise ?? (abs(rawPy) < 40 && rawPy != 0 && rawPy % 100 != 0 && rawPy % 120 != 0)

        if continuous {
            // High-frequency continuous touchpad gesture: 1:1 direct injection
            smoothScroller.stop()
            let src = CGEventSource(stateID: .hidSystemState)
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                  wheelCount: 2, wheel1: Int32(-rawPy), wheel2: Int32(-rawPx), wheel3: 0) else { return }
            scrollLock.lock()
            let loc = lastMousePoint
            scrollLock.unlock()
            if loc != .zero {
                e.location = loc
            }

            scrollLock.lock()
            scrollEndWorkItem?.cancel()
            let phase: CGScrollPhase = isScrollingContinuous ? .changed : .began
            isScrollingContinuous = true
            scrollLock.unlock()

            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(-rawPy))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(-rawPx))
            timedPost(e, tap: .cgSessionEventTap)

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scrollLock.lock()
                guard self.isScrollingContinuous else { self.scrollLock.unlock(); return }
                self.isScrollingContinuous = false
                let endLoc = self.lastMousePoint
                self.scrollLock.unlock()

                if let endEvent = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                          wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
                    if endLoc != .zero {
                        endEvent.location = endLoc
                    }
                    endEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    endEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
                    self.timedPost(endEvent, tap: .cgSessionEventTap)
                }
            }
            scrollLock.lock()
            scrollEndWorkItem = work
            scrollLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            // Mechanical mouse wheel notch (Windows / USB mouse):
            // Smooth 120Hz physics interpolation gives butter-smooth ProMotion feel
            smoothScroller.addDelta(px: Double(-rawPx), py: Double(-rawPy))
        }
    }

    // Software-simulated Caps Lock: on modern macOS, neither IOHIDSetModifierLockState
    // nor a synthetic HID keyDown/keyUp for virtualKey 57 actually flips the system's
    // persisted lock state anymore (confirmed not to work even as root) — Apple has
    // locked this down, with no lightweight public replacement. So instead of toggling
    // real OS state, we track our own flag and force-apply Shift to subsequent letter
    // keys ourselves, same as how a real CapsLock+Shift combo behaves.
    private var virtualCapsLockOn = false

    func keyEvent(code: String, down: Bool, modifiers: [String]) {
        if code == "CapsLock" {
            if down { virtualCapsLockOn.toggle() }
            return
        }

        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyCode = keyCodeMap[code] else {
            NSLog("[Input] keyEvent: unknown code=%@", code)
            return
        }
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else {
            NSLog("[Input] keyEvent: CGEvent creation failed code=%@", code)
            return
        }

        var shiftActive = modifiers.contains("shift")
        if virtualCapsLockOn && code.hasPrefix("Key") { shiftActive.toggle() }

        var flags = CGEventFlags()
        for mod in modifiers {
            switch mod {
            case "meta", "cmd": flags.insert(.maskCommand)
            case "shift":       break // handled via shiftActive below
            case "alt":         flags.insert(.maskAlternate)
            case "ctrl":        flags.insert(.maskControl)
            default: break
            }
        }
        if shiftActive { flags.insert(.maskShift) }
        e.flags = flags
        timedPost(e, tap: .cgAnnotatedSessionEventTap)

        if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
    }

    /// Injects a unicode string directly (IME-composed text from the client
    /// — Chinese/Japanese/Korean etc). Raw key forwarding can't express
    /// composed text at all: the composition happened on the *client's* IME,
    /// so what arrives here is final text with no key sequence behind it.
    /// CGEvent carries the string via keyboardSetUnicodeString; chunked at
    /// 20 UTF-16 units per event, the documented safe payload limit.
    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 20, utf16.count)])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            timedPost(down, tap: .cgAnnotatedSessionEventTap)
            timedPost(up,   tap: .cgAnnotatedSessionEventTap)
            i += 20
        }
    }

    func releaseAllKeys() {
        guard !pressedKeys.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for keyCode in pressedKeys {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { continue }
            e.flags = []
            timedPost(e, tap: .cgAnnotatedSessionEventTap)
        }
        pressedKeys.removeAll()
    }

    // MARK: - Private

    private func cgPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: originX + x * Double(screenWidth), y: originY + y * Double(screenHeight))
    }
}

// Web KeyboardEvent.code → macOS virtual key code
private let keyCodeMap: [String: CGKeyCode] = [
    "KeyA": 0,   "KeyS": 1,   "KeyD": 2,   "KeyF": 3,   "KeyH": 4,   "KeyG": 5,
    "KeyZ": 6,   "KeyX": 7,   "KeyC": 8,   "KeyV": 9,   "KeyB": 11,  "KeyQ": 12,
    "KeyW": 13,  "KeyE": 14,  "KeyR": 15,  "KeyY": 16,  "KeyT": 17,
    "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22,
    "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
    "Digit8": 28, "Digit0": 29, "BracketRight": 30,
    "KeyO": 31,  "KeyU": 32,  "BracketLeft": 33, "KeyI": 34, "KeyP": 35,
    "Enter": 36, "KeyL": 37,  "KeyJ": 38,  "Quote": 39, "KeyK": 40,
    "Semicolon": 41, "Backslash": 42, "Comma": 43, "Slash": 44,
    "KeyN": 45,  "KeyM": 46,  "Period": 47, "Tab": 48,  "Space": 49,
    "Backquote": 50, "Backspace": 51, "Escape": 53,
    "MetaLeft": 55,  "MetaRight": 54, "ShiftLeft": 56,  "CapsLock": 57,
    "AltLeft": 58,   "ControlLeft": 59, "ShiftRight": 60, "AltRight": 61,
    "ControlRight": 62,
    "F1": 122, "F2": 120, "F3": 99,  "F4": 118, "F5": 96,  "F6": 97,
    "F7": 98,  "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
    "F13": 105, "F14": 107, "F15": 113, "F16": 106, "F17": 64, "F18": 72,
    "F19": 73,  "F20": 90,
    "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
    "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
    "Delete": 117, "Insert": 114, "NumLock": 71,
    "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85, "Numpad4": 86,
    "Numpad5": 87, "Numpad6": 88, "Numpad7": 89, "Numpad8": 91, "Numpad9": 92,
    "NumpadDecimal": 65, "NumpadMultiply": 67, "NumpadAdd": 69,
    "NumpadSubtract": 78, "NumpadDivide": 75, "NumpadEnter": 76, "NumpadEqual": 81,
]

// MARK: - SmoothScrollEngine (借鉴 Mos & UU 远程 120Hz 丝滑阻尼物理引擎)

final class SmoothScrollEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var targetY: Double = 0
    private var targetX: Double = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.remoter.smoothscroll", qos: .userInteractive)
    private var isAnimating = false
    private weak var controller: InputController?

    init(controller: InputController) {
        self.controller = controller
    }

    func addDelta(px: Double, py: Double) {
        lock.lock()
        targetX += px
        targetY += py
        let needStart = !isAnimating
        isAnimating = true
        lock.unlock()

        if needStart {
            startTimer()
        }
    }

    private func startTimer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // 120Hz 刷新率: 每 8.3ms 一帧
            t.schedule(deadline: .now(), repeating: .milliseconds(8))
            var isFirst = true

            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()

                // 指数衰减系数 0.22：兼顾疾速跟手与丝滑渐停
                let friction = 0.22
                var stepY = self.targetY * friction
                var stepX = self.targetX * friction

                // 小余量快速收敛，避免无限微步拖尾
                if abs(stepY) < 1.0 || abs(self.targetY) < 1.0 {
                    stepY = self.targetY
                }
                if abs(stepX) < 1.0 || abs(self.targetX) < 1.0 {
                    stepX = self.targetX
                }

                self.targetY -= stepY
                self.targetX -= stepX

                let remainingY = self.targetY
                let remainingX = self.targetX
                let isEnding = abs(remainingY) < 0.2 && abs(remainingX) < 0.2
                if isEnding {
                    self.targetY = 0
                    self.targetX = 0
                    self.isAnimating = false
                    self.timer?.cancel()
                    self.timer = nil
                }
                let first = isFirst
                isFirst = false
                self.lock.unlock()

                let phase: CGScrollPhase = first ? .began : (isEnding ? .ended : .changed)
                let intStepY = Int32(round(stepY))
                let intStepX = Int32(round(stepX))

                if intStepY != 0 || intStepX != 0 || isEnding {
                    self.controller?.injectScrollStep(stepX: intStepX, stepY: intStepY, phase: phase)
                }
            }

            self.timer = t
            self.lock.unlock()
            t.resume()
        }
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        targetX = 0
        targetY = 0
        if isAnimating {
            isAnimating = false
            lock.unlock()
            controller?.injectScrollStep(stepX: 0, stepY: 0, phase: .ended)
        } else {
            lock.unlock()
        }
    }
}
