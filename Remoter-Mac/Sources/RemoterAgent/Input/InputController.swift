import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import IOKit
import IOKit.hidsystem

final class InputController {
    var screenWidth: Int
    var screenHeight: Int
    private var loggedAccessibility = false
    private var pressedKeys = Set<CGKeyCode>()

    init(screenWidth: Int, screenHeight: Int) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
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
        e.post(tap: .cgSessionEventTap)
    }

    func mouseButton(button: String, down: Bool, x: Double, y: Double) {
        let pt = cgPoint(x: x, y: y)
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
        e.post(tap: .cgSessionEventTap)
    }

    func mouseDoubleClick(button: String, x: Double, y: Double) {
        let pt  = cgPoint(x: x, y: y)
        let src = CGEventSource(stateID: .hidSystemState)
        let type: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
        let btn: CGMouseButton = button == "right" ? .right : .left
        guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: btn) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 2)
        e.post(tap: .cgSessionEventTap)
        guard let eu = CGEvent(mouseEventSource: src,
                               mouseType: button == "right" ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: pt, mouseButton: btn) else { return }
        eu.setIntegerValueField(.mouseEventClickState, value: 2)
        eu.post(tap: .cgSessionEventTap)
    }

    func mouseScroll(dx: Int, dy: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                              wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        e.post(tap: .cgSessionEventTap)
    }

    func keyEvent(code: String, down: Bool, modifiers: [String]) {
        // CapsLock is a lock key, not a momentary one: posting a synthetic CGEvent with
        // .maskAlphaShift only flags that single event, it does not flip the system's
        // persisted lock state. Toggling it for real requires IOHIDSystem.
        // Client already deduplicates and sends one down+up pair per toggle.
        if code == "CapsLock" {
            if down {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
                if service == 0 {
                    NSLog("[Input] CapsLock: IOServiceGetMatchingService found no kIOHIDSystemClass service")
                    return
                }
                var ioConnect: io_connect_t = 0
                let openErr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &ioConnect)
                IOObjectRelease(service)
                if openErr != KERN_SUCCESS {
                    NSLog("[Input] CapsLock: IOServiceOpen failed err=%d", openErr)
                    return
                }
                var capsCurrentlyOn: Bool = false
                let getErr = IOHIDGetModifierLockState(ioConnect, Int32(kIOHIDCapsLockState), &capsCurrentlyOn)
                let setErr = IOHIDSetModifierLockState(ioConnect, Int32(kIOHIDCapsLockState), !capsCurrentlyOn)
                NSLog("[Input] CapsLock: getErr=%d currentlyOn=%d setErr=%d newState=%d",
                      getErr, capsCurrentlyOn ? 1 : 0, setErr, !capsCurrentlyOn ? 1 : 0)
                IOServiceClose(ioConnect)
            }
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

        var flags = CGEventFlags()
        for mod in modifiers {
            switch mod {
            case "meta", "cmd": flags.insert(.maskCommand)
            case "shift":       flags.insert(.maskShift)
            case "alt":         flags.insert(.maskAlternate)
            case "ctrl":        flags.insert(.maskControl)
            default: break
            }
        }
        e.flags = flags
        e.post(tap: .cgAnnotatedSessionEventTap)

        if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
    }

    func releaseAllKeys() {
        guard !pressedKeys.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for keyCode in pressedKeys {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { continue }
            e.flags = []
            e.post(tap: .cgAnnotatedSessionEventTap)
        }
        pressedKeys.removeAll()
    }

    // MARK: - Private

    private func cgPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x * Double(screenWidth), y: y * Double(screenHeight))
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
