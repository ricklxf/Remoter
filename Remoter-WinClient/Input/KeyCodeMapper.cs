using System.Runtime.InteropServices;

namespace RemoterWinClient.Input;

/// <summary>
/// Maps Windows Virtual-Key (VK) + hardware scan code + extended flag
/// to standard W3C / JS KeyboardEvent.code strings matching Remoter-Mac &amp; Remoter-Win agents.
/// </summary>
public static class KeyCodeMapper
{
    private const uint MAPVK_VSC_TO_VK_EX = 3;

    private const int VK_SHIFT    = 0x10;
    private const int VK_CONTROL  = 0x11;
    private const int VK_MENU     = 0x12;
    private const int VK_LSHIFT   = 0xA0;
    private const int VK_RSHIFT   = 0xA1;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LMENU    = 0xA4;
    private const int VK_RMENU    = 0xA5;
    private const int VK_LWIN     = 0x5B;
    private const int VK_RWIN     = 0x5C;

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    /// <summary>
    /// Converts WM_KEYDOWN/WM_KEYUP/WM_SYSKEYDOWN/WM_SYSKEYUP wParam + lParam
    /// into a W3C KeyboardEvent.code string (e.g. "KeyA", "ControlLeft", "NumpadEnter").
    /// </summary>
    public static string? MapToJsCode(nint wParam, nint lParam)
    {
        int vk = (int)(wParam & 0xFFFF);
        long lp = lParam;
        uint scanCode = (uint)((lp >> 16) & 0xFF);
        bool extended = ((lp >> 24) & 1) != 0;

        return MapToJsCode(vk, scanCode, extended);
    }

    /// <summary>
    /// Converts Windows VK, scan code, and extended flag into a W3C KeyboardEvent.code string.
    /// </summary>
    public static string? MapToJsCode(int vk, uint scanCode, bool extended)
    {
        // Disambiguate left/right modifier keys
        if (vk == VK_SHIFT)
        {
            uint exVk = MapVirtualKeyW(scanCode, MAPVK_VSC_TO_VK_EX);
            return exVk == VK_RSHIFT ? "ShiftRight" : "ShiftLeft";
        }
        if (vk == VK_CONTROL)
            return extended ? "ControlRight" : "ControlLeft";
        if (vk == VK_MENU)
            return extended ? "AltRight" : "AltLeft";

        // Disambiguate Enter vs NumpadEnter
        if (vk == 0x0D)
            return extended ? "NumpadEnter" : "Enter";

        // Disambiguate dedicated navigation keys (extended=true) vs numpad keys when NumLock is off (extended=false)
        if (!extended)
        {
            switch (vk)
            {
                case 0x2D: return "Numpad0";       // VK_INSERT on numpad
                case 0x23: return "Numpad1";       // VK_END on numpad
                case 0x28: return "Numpad2";       // VK_DOWN on numpad
                case 0x22: return "Numpad3";       // VK_NEXT (PageDown) on numpad
                case 0x25: return "Numpad4";       // VK_LEFT on numpad
                case 0x0C: return "Numpad5";       // VK_CLEAR on numpad
                case 0x27: return "Numpad6";       // VK_RIGHT on numpad
                case 0x24: return "Numpad7";       // VK_HOME on numpad
                case 0x26: return "Numpad8";       // VK_UP on numpad
                case 0x21: return "Numpad9";       // VK_PRIOR (PageUp) on numpad
                case 0x2E: return "NumpadDecimal"; // VK_DELETE on numpad
            }
        }

        // Standard letters A-Z
        if (vk >= 0x41 && vk <= 0x5A)
            return $"Key{(char)vk}";

        // Top-row digits 0-9
        if (vk >= 0x30 && vk <= 0x39)
            return $"Digit{(char)vk}";

        // Function keys F1-F12 (and F13-F24)
        if (vk >= 0x70 && vk <= 0x87)
            return $"F{vk - 0x70 + 1}";

        // Numpad digits 0-9 (when NumLock is on)
        if (vk >= 0x60 && vk <= 0x69)
            return $"Numpad{vk - 0x60}";

        return vk switch
        {
            0x08 => "Backspace",
            0x09 => "Tab",
            0x13 => "Pause",
            0x14 => "CapsLock",
            0x1B => "Escape",
            0x20 => "Space",
            0x21 => "PageUp",
            0x22 => "PageDown",
            0x23 => "End",
            0x24 => "Home",
            0x25 => "ArrowLeft",
            0x26 => "ArrowUp",
            0x27 => "ArrowRight",
            0x28 => "ArrowDown",
            0x2C => "PrintScreen",
            0x2D => "Insert",
            0x2E => "Delete",

            VK_LWIN     => "MetaLeft",
            VK_RWIN     => "MetaRight",
            0x5D        => "ContextMenu",
            VK_LSHIFT   => "ShiftLeft",
            VK_RSHIFT   => "ShiftRight",
            VK_LCONTROL => "ControlLeft",
            VK_RCONTROL => "ControlRight",
            VK_LMENU    => "AltLeft",
            VK_RMENU    => "AltRight",

            0x6A => "NumpadMultiply",
            0x6B => "NumpadAdd",
            0x6D => "NumpadSubtract",
            0x6E => "NumpadDecimal",
            0x6F => "NumpadDivide",

            0x90 => "NumLock",
            0x91 => "ScrollLock",

            0xBA => "Semicolon",
            0xBB => "Equal",
            0xBC => "Comma",
            0xBD => "Minus",
            0xBE => "Period",
            0xBF => "Slash",
            0xC0 => "Backquote",
            0xDB => "BracketLeft",
            0xDC => "Backslash",
            0xDD => "BracketRight",
            0xDE => "Quote",
            0xE2 => "IntlBackslash",

            _ => null,
        };
    }

    public static bool IsKeyDown(int vk) => (GetKeyState(vk) & 0x8000) != 0;

    /// <summary>
    /// Collects currently depressed modifier keys in Remoter wire format: "ctrl", "shift", "alt", "meta".
    /// </summary>
    public static string[] CollectModifiers()
    {
        var mods = new List<string>(4);
        if (IsKeyDown(VK_CONTROL) || IsKeyDown(VK_LCONTROL) || IsKeyDown(VK_RCONTROL))
            mods.Add("ctrl");
        if (IsKeyDown(VK_SHIFT) || IsKeyDown(VK_LSHIFT) || IsKeyDown(VK_RSHIFT))
            mods.Add("shift");
        if (IsKeyDown(VK_MENU) || IsKeyDown(VK_LMENU) || IsKeyDown(VK_RMENU))
            mods.Add("alt");
        if (IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN))
            mods.Add("meta");
        return mods.ToArray();
    }
}
