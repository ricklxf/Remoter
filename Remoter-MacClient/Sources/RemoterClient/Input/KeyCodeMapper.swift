import Foundation
import AppKit
import Carbon.HIToolbox

/// Maps macOS `CGKeyCode` (`Carbon.HIToolbox`) to W3C / JS `KeyboardEvent.code` strings
/// matching Remoter-Mac & Remoter-Win agents, with optional Mac ↔ Windows modifier swapping.
public enum KeyCodeMapper {

    /// Maps a macOS hardware `CGKeyCode` to a W3C `KeyboardEvent.code` string.
    /// When `swapMacToWinModifiers` is `true`, `MetaLeft/Right` (Command) and `ControlLeft/Right`
    /// are swapped so macOS Cmd+C/V/A/Z behaves like Windows Ctrl+C/V/A/Z.
    public static func mapKeyCode(_ keyCode: UInt16, swapMacToWinModifiers: Bool = false) -> String? {
        guard let rawCode = rawMapKeyCode(Int(keyCode)) else { return nil }
        guard swapMacToWinModifiers else { return rawCode }

        switch rawCode {
        case "MetaLeft":     return "ControlLeft"
        case "MetaRight":    return "ControlRight"
        case "ControlLeft":  return "MetaLeft"
        case "ControlRight": return "MetaRight"
        default:             return rawCode
        }
    }

    /// Collects currently active modifier flags in Remoter wire format: `"ctrl"`, `"shift"`, `"alt"`, `"meta"`.
    public static func collectModifiers(
        from flags: NSEvent.ModifierFlags,
        swapMacToWinModifiers: Bool = false
    ) -> [String] {
        var mods: [String] = []
        mods.reserveCapacity(4)

        let ctrlActive = swapMacToWinModifiers ? flags.contains(.command) : flags.contains(.control)
        let metaActive = swapMacToWinModifiers ? flags.contains(.control) : flags.contains(.command)

        if ctrlActive { mods.append("ctrl") }
        if flags.contains(.shift) { mods.append("shift") }
        if flags.contains(.option) { mods.append("alt") }
        if metaActive { mods.append("meta") }

        return mods
    }

    /// Returns true if the given macOS keyCode is a modifier key handled via `flagsChanged`.
    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift,
             kVK_Control, kVK_RightControl,
             kVK_Option, kVK_RightOption,
             kVK_Command, kVK_RightCommand,
             kVK_CapsLock:
            return true
        default:
            return false
        }
    }

    // MARK: - Full macOS CGKeyCode -> W3C KeyboardEvent.code Table

    private static func rawMapKeyCode(_ keyCode: Int) -> String? {
        switch keyCode {
        // Letters A-Z
        case kVK_ANSI_A: return "KeyA"
        case kVK_ANSI_B: return "KeyB"
        case kVK_ANSI_C: return "KeyC"
        case kVK_ANSI_D: return "KeyD"
        case kVK_ANSI_E: return "KeyE"
        case kVK_ANSI_F: return "KeyF"
        case kVK_ANSI_G: return "KeyG"
        case kVK_ANSI_H: return "KeyH"
        case kVK_ANSI_I: return "KeyI"
        case kVK_ANSI_J: return "KeyJ"
        case kVK_ANSI_K: return "KeyK"
        case kVK_ANSI_L: return "KeyL"
        case kVK_ANSI_M: return "KeyM"
        case kVK_ANSI_N: return "KeyN"
        case kVK_ANSI_O: return "KeyO"
        case kVK_ANSI_P: return "KeyP"
        case kVK_ANSI_Q: return "KeyQ"
        case kVK_ANSI_R: return "KeyR"
        case kVK_ANSI_S: return "KeyS"
        case kVK_ANSI_T: return "KeyT"
        case kVK_ANSI_U: return "KeyU"
        case kVK_ANSI_V: return "KeyV"
        case kVK_ANSI_W: return "KeyW"
        case kVK_ANSI_X: return "KeyX"
        case kVK_ANSI_Y: return "KeyY"
        case kVK_ANSI_Z: return "KeyZ"

        // Top-row digits 0-9
        case kVK_ANSI_0: return "Digit0"
        case kVK_ANSI_1: return "Digit1"
        case kVK_ANSI_2: return "Digit2"
        case kVK_ANSI_3: return "Digit3"
        case kVK_ANSI_4: return "Digit4"
        case kVK_ANSI_5: return "Digit5"
        case kVK_ANSI_6: return "Digit6"
        case kVK_ANSI_7: return "Digit7"
        case kVK_ANSI_8: return "Digit8"
        case kVK_ANSI_9: return "Digit9"

        // Punctuation & symbols
        case kVK_ANSI_Grave:        return "Backquote"
        case kVK_ANSI_Minus:        return "Minus"
        case kVK_ANSI_Equal:        return "Equal"
        case kVK_ANSI_LeftBracket:  return "BracketLeft"
        case kVK_ANSI_RightBracket: return "BracketRight"
        case kVK_ANSI_Backslash:    return "Backslash"
        case kVK_ANSI_Semicolon:    return "Semicolon"
        case kVK_ANSI_Quote:        return "Quote"
        case kVK_ANSI_Comma:        return "Comma"
        case kVK_ANSI_Period:       return "Period"
        case kVK_ANSI_Slash:        return "Slash"
        case kVK_ISO_Section:       return "IntlBackslash"

        // Whitespace, control & editing
        case kVK_Return:        return "Enter"
        case kVK_Tab:           return "Tab"
        case kVK_Space:         return "Space"
        case kVK_Delete:        return "Backspace"
        case kVK_ForwardDelete: return "Delete"
        case kVK_Escape:        return "Escape"
        case kVK_Help:          return "Insert"

        // Arrow keys
        case kVK_LeftArrow:  return "ArrowLeft"
        case kVK_RightArrow: return "ArrowRight"
        case kVK_DownArrow:  return "ArrowDown"
        case kVK_UpArrow:    return "ArrowUp"

        // Navigation cluster
        case kVK_Home:     return "Home"
        case kVK_End:      return "End"
        case kVK_PageUp:   return "PageUp"
        case kVK_PageDown: return "PageDown"

        // Function keys F1-F20
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"

        // Numpad
        case kVK_ANSI_Keypad0:        return "Numpad0"
        case kVK_ANSI_Keypad1:        return "Numpad1"
        case kVK_ANSI_Keypad2:        return "Numpad2"
        case kVK_ANSI_Keypad3:        return "Numpad3"
        case kVK_ANSI_Keypad4:        return "Numpad4"
        case kVK_ANSI_Keypad5:        return "Numpad5"
        case kVK_ANSI_Keypad6:        return "Numpad6"
        case kVK_ANSI_Keypad7:        return "Numpad7"
        case kVK_ANSI_Keypad8:        return "Numpad8"
        case kVK_ANSI_Keypad9:        return "Numpad9"
        case kVK_ANSI_KeypadDecimal:  return "NumpadDecimal"
        case kVK_ANSI_KeypadMultiply: return "NumpadMultiply"
        case kVK_ANSI_KeypadPlus:     return "NumpadAdd"
        case kVK_ANSI_KeypadMinus:    return "NumpadSubtract"
        case kVK_ANSI_KeypadDivide:   return "NumpadDivide"
        case kVK_ANSI_KeypadEnter:    return "NumpadEnter"
        case kVK_ANSI_KeypadEquals:   return "NumpadEqual"
        case kVK_ANSI_KeypadClear:    return "NumLock"

        // Modifiers
        case kVK_Shift:        return "ShiftLeft"
        case kVK_RightShift:   return "ShiftRight"
        case kVK_Control:      return "ControlLeft"
        case kVK_RightControl: return "ControlRight"
        case kVK_Option:       return "AltLeft"
        case kVK_RightOption:  return "AltRight"
        case kVK_Command:      return "MetaLeft"
        case kVK_RightCommand: return "MetaRight"
        case kVK_CapsLock:     return "CapsLock"

        // Contextual menu key (macOS virtual key 110 / 0x6E)
        case 0x6E:             return "ContextMenu"

        default:
            return nil
        }
    }
}
