using System.Runtime.InteropServices;

namespace RemoterWin;

// Win32 SendInput wrapper.
// Coordinates are normalised [0, 1] — same as Mac agent.
sealed class InputController
{
    public InputController(int screenWidth, int screenHeight)
    {
        _sw = screenWidth;
        _sh = screenHeight;
    }

    private readonly int _sw, _sh;
    private int _moveLogN = 0;

    // ── Mouse ──────────────────────────────────────────────────────────

    public void MouseMove(double xNorm, double yNorm)
    {
        int ax = Norm(xNorm);
        int ay = Norm(yNorm);
        bool log = _moveLogN++ < 3;
        uint sent = SendInput(1, [new INPUT
        {
            type = IT_MOUSE,
            mi   = new MOUSEINPUT
            {
                dx      = ax, dy = ay,
                dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
            }
        }], Marshal.SizeOf<INPUT>());
        if (log)
            AppLog.Write($"[Input] Move ax={ax} ay={ay} sent={sent} err=0x{Marshal.GetLastWin32Error():X8}");
        else if (sent == 0)
            AppLog.Write($"[Input] Move failed err=0x{Marshal.GetLastWin32Error():X8}");
    }

    public void MouseButton(string button, bool down, double xNorm, double yNorm)
    {
        int ax = Norm(xNorm);
        int ay = Norm(yNorm);
        uint flags = button switch
        {
            "right"  => down ? MOUSEEVENTF_RIGHTDOWN  : MOUSEEVENTF_RIGHTUP,
            "middle" => down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP,
            _        => down ? MOUSEEVENTF_LEFTDOWN   : MOUSEEVENTF_LEFTUP,
        };
        SendInput1(new INPUT
        {
            type = IT_MOUSE,
            mi   = new MOUSEINPUT
            {
                dx = ax, dy = ay,
                dwFlags = flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
            }
        });
    }

    public void MouseDoubleClick(string button, double xNorm, double yNorm)
    {
        int ax = Norm(xNorm);
        int ay = Norm(yNorm);
        uint downFlag = button switch
        {
            "right"  => MOUSEEVENTF_RIGHTDOWN,
            "middle" => MOUSEEVENTF_MIDDLEDOWN,
            _        => MOUSEEVENTF_LEFTDOWN,
        };
        uint upFlag = button switch
        {
            "right"  => MOUSEEVENTF_RIGHTUP,
            "middle" => MOUSEEVENTF_MIDDLEUP,
            _        => MOUSEEVENTF_LEFTUP,
        };
        uint abs = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        // Two click cycles at the same position
        SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT { dx = ax, dy = ay, dwFlags = downFlag | abs } });
        SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT { dx = ax, dy = ay, dwFlags = upFlag   | abs } });
        SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT { dx = ax, dy = ay, dwFlags = downFlag | abs } });
        SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT { dx = ax, dy = ay, dwFlags = upFlag   | abs } });
    }

    public void MouseScroll(int dx, int dy)
    {
        if (dy != 0)
            SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT
                { dwFlags = MOUSEEVENTF_WHEEL, mouseData = (uint)(-dy * WHEEL_DELTA) } });
        if (dx != 0)
            SendInput1(new INPUT { type = IT_MOUSE, mi = new MOUSEINPUT
                { dwFlags = MOUSEEVENTF_HWHEEL, mouseData = (uint)(dx * WHEEL_DELTA) } });
    }

    // ── Keyboard ────────────────────────────────────────────────────────

    public void KeyEvent(string code, bool down, string[] modifiers)
    {
        // Send modifier keys first (down only), then the main key, then release mods
        if (down)
        {
            foreach (var mod in modifiers) SendKey(ModVk(mod), down: true);
        }

        if (KeyCodeToVk.TryGetValue(code, out var vk))
            SendKey(vk, down);
        else
            AppLog.Write($"[Input] Unknown key code: {code}");
    }

    private static ushort ModVk(string mod) => mod switch
    {
        "ctrl"  or "Control" => VK_LCONTROL,
        "shift" or "Shift"   => VK_LSHIFT,
        "alt"   or "Alt"     => VK_LMENU,
        "meta"  or "Meta"    => VK_LWIN,
        _                    => 0,
    };

    private static void SendKey(ushort vk, bool down)
    {
        if (vk == 0) return;
        SendInput1(new INPUT
        {
            type = IT_KEYBOARD,
            ki   = new KEYBDINPUT
            {
                wVk      = vk,
                dwFlags  = down ? 0u : KEYEVENTF_KEYUP,
            }
        });
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    // Converts [0,1] normalised coordinate to MOUSEEVENTF_ABSOLUTE range [0, 65535]
    private static int Norm(double v) => (int)Math.Clamp(v * 65535.0, 0, 65535);

    private static void SendInput1(INPUT input)
    {
        if (SendInput(1, [input], Marshal.SizeOf<INPUT>()) == 0)
            AppLog.Write($"[Input] SendInput failed: 0x{Marshal.GetLastWin32Error():X8}");
    }

    // ── P/Invoke ─────────────────────────────────────────────────────────

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const uint IT_MOUSE    = 0;
    private const uint IT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_MOVE        = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP      = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN   = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP     = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN  = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP    = 0x0040;
    private const uint MOUSEEVENTF_WHEEL       = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL      = 0x1000;
    private const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const int  WHEEL_DELTA             = 120;

    private const uint KEYEVENTF_KEYUP = 0x0002;

    private const ushort VK_LCONTROL = 0xA2;
    private const ushort VK_LSHIFT   = 0xA0;
    private const ushort VK_LMENU    = 0xA4;
    private const ushort VK_LWIN     = 0x5B;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
        // Alias fields for convenience
        public MOUSEINPUT   mi   { get => U.mi;   set => U.mi   = value; }
        public KEYBDINPUT   ki   { get => U.ki;   set => U.ki   = value; }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT   mi;
        [FieldOffset(0)] public KEYBDINPUT   ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int    dx, dy;
        public uint   mouseData;
        public uint   dwFlags;
        public uint   time;
        public nint   dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint   dwFlags;
        public uint   time;
        public nint   dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint  uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    // Web KeyboardEvent.code → Windows virtual key code
    // Same mapping as Mac agent (Web standard → platform VK)
    private static readonly Dictionary<string, ushort> KeyCodeToVk = new()
    {
        ["KeyA"] = 0x41, ["KeyB"] = 0x42, ["KeyC"] = 0x43, ["KeyD"] = 0x44,
        ["KeyE"] = 0x45, ["KeyF"] = 0x46, ["KeyG"] = 0x47, ["KeyH"] = 0x48,
        ["KeyI"] = 0x49, ["KeyJ"] = 0x4A, ["KeyK"] = 0x4B, ["KeyL"] = 0x4C,
        ["KeyM"] = 0x4D, ["KeyN"] = 0x4E, ["KeyO"] = 0x4F, ["KeyP"] = 0x50,
        ["KeyQ"] = 0x51, ["KeyR"] = 0x52, ["KeyS"] = 0x53, ["KeyT"] = 0x54,
        ["KeyU"] = 0x55, ["KeyV"] = 0x56, ["KeyW"] = 0x57, ["KeyX"] = 0x58,
        ["KeyY"] = 0x59, ["KeyZ"] = 0x5A,

        ["Digit0"] = 0x30, ["Digit1"] = 0x31, ["Digit2"] = 0x32, ["Digit3"] = 0x33,
        ["Digit4"] = 0x34, ["Digit5"] = 0x35, ["Digit6"] = 0x36, ["Digit7"] = 0x37,
        ["Digit8"] = 0x38, ["Digit9"] = 0x39,

        ["F1"]  = 0x70, ["F2"]  = 0x71, ["F3"]  = 0x72, ["F4"]  = 0x73,
        ["F5"]  = 0x74, ["F6"]  = 0x75, ["F7"]  = 0x76, ["F8"]  = 0x77,
        ["F9"]  = 0x78, ["F10"] = 0x79, ["F11"] = 0x7A, ["F12"] = 0x7B,

        ["Enter"]      = 0x0D, ["Escape"]    = 0x1B, ["Backspace"] = 0x08,
        ["Tab"]        = 0x09, ["Space"]     = 0x20, ["Delete"]    = 0x2E,
        ["Insert"]     = 0x2D, ["Home"]      = 0x24, ["End"]       = 0x23,
        ["PageUp"]     = 0x21, ["PageDown"]  = 0x22, ["CapsLock"]  = 0x14,
        ["NumLock"]    = 0x90, ["ScrollLock"]= 0x91, ["PrintScreen"]= 0x2C,
        ["Pause"]      = 0x13,

        ["ArrowLeft"]  = 0x25, ["ArrowUp"]   = 0x26,
        ["ArrowRight"] = 0x27, ["ArrowDown"] = 0x28,

        ["ShiftLeft"]   = 0xA0, ["ShiftRight"]   = 0xA1,
        ["ControlLeft"] = 0xA2, ["ControlRight"] = 0xA3,
        ["AltLeft"]     = 0xA4, ["AltRight"]     = 0xA5,
        ["MetaLeft"]    = 0x5B, ["MetaRight"]    = 0x5C,

        ["Minus"]        = 0xBD, ["Equal"]        = 0xBB,
        ["BracketLeft"]  = 0xDB, ["BracketRight"] = 0xDD,
        ["Backslash"]    = 0xDC, ["Semicolon"]    = 0xBA,
        ["Quote"]        = 0xDE, ["Backquote"]    = 0xC0,
        ["Comma"]        = 0xBC, ["Period"]       = 0xBE,
        ["Slash"]        = 0xBF,

        ["Numpad0"] = 0x60, ["Numpad1"] = 0x61, ["Numpad2"] = 0x62,
        ["Numpad3"] = 0x63, ["Numpad4"] = 0x64, ["Numpad5"] = 0x65,
        ["Numpad6"] = 0x66, ["Numpad7"] = 0x67, ["Numpad8"] = 0x68,
        ["Numpad9"] = 0x69, ["NumpadDecimal"]  = 0x6E,
        ["NumpadMultiply"] = 0x6A, ["NumpadAdd"]      = 0x6B,
        ["NumpadSubtract"] = 0x6D, ["NumpadDivide"]   = 0x6F,
        ["NumpadEnter"]    = 0x0D,
    };
}
