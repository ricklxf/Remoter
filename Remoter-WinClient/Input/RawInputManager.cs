using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using RemoterWinClient.UI;

namespace RemoterWinClient.Input;

/// <summary>
/// Pure Win32 RawInput &amp; input pipeline manager for Remoter-WinClient:
/// - High-polling-rate RawInput mouse + 3D game relative mouse mode (Pointer Lock via ClipCursor + ShowCursor)
/// - Normalized [0, 1] coordinate mapping accounting for Fit/Stretch/Original content rect &amp; Per-Monitor V2 DPI
/// - Smooth precision touchpad &amp; discrete wheel handling with sub-notch preservation, soft axis lock, and 120Hz coalescing
/// - Full Windows VK/ScanCode -> JS KeyboardEvent.code mapping, Win/Alt interception, and release-all-keys on focus loss
/// </summary>
public sealed class RawInputManager : IDisposable
{
    private const uint RID_INPUT         = 0x10000003;
    private const uint RIM_TYPEMOUSE     = 0;
    private const ushort HID_USAGE_PAGE_GENERIC = 0x01;
    private const ushort HID_USAGE_GENERIC_MOUSE = 0x02;

    private const ushort MOUSE_MOVE_ABSOLUTE       = 0x0001;
    private const ushort RI_MOUSE_LEFT_BUTTON_DOWN = 0x0001;
    private const ushort RI_MOUSE_LEFT_BUTTON_UP   = 0x0002;
    private const ushort RI_MOUSE_RIGHT_BUTTON_DOWN = 0x0004;
    private const ushort RI_MOUSE_RIGHT_BUTTON_UP   = 0x0008;
    private const ushort RI_MOUSE_MIDDLE_BUTTON_DOWN = 0x0010;
    private const ushort RI_MOUSE_MIDDLE_BUTTON_UP   = 0x0020;

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_KEYUP       = 0x0101;
    private const int WM_SYSKEYDOWN  = 0x0104;
    private const int WM_SYSKEYUP    = 0x0105;
    private const int VK_LWIN        = 0x5B;
    private const int VK_RWIN        = 0x5C;

    private const double MoveThrottleMs   = 8.0; // 120Hz
    private const double ScrollThrottleMs = 8.0; // 120Hz

    private readonly VideoHostControl _host;
    private readonly System.Windows.Forms.Timer _moveFlushTimer;
    private readonly System.Windows.Forms.Timer _scrollFlushTimer;
    private readonly HashSet<string> _pressedKeys = new(StringComparer.Ordinal);

    private bool _enabled = true;
    private bool _pointerLocked;
    private bool _cursorHidden;
    private bool _disposed;
    private bool _windowActive = true;

    // Remote desktop dimensions (used to scale relative pointer-lock deltas)
    private int _remoteWidth = 1920;
    private int _remoteHeight = 1080;

    // Active video viewport rectangle inside VideoHostControl (client physical pixels)
    private Rectangle _contentRect;

    // Virtual normalized cursor position in Pointer Lock mode
    private double _curNormX = 0.5;
    private double _curNormY = 0.5;
    private MouseButtons _heldButtons = MouseButtons.None;

    // 120Hz trailing-edge mouse move throttling
    private long _lastMoveSentTick;
    private bool _hasPendingMove;
    private double _pendingMoveNx;
    private double _pendingMoveNy;
    private string? _pendingMoveDrag;

    // 120Hz precision touchpad scroll coalescing & sub-unit remainders (UU-Remote gesture tracking)
    private const double PreciseStickyWindowMs = 60.0;
    private const double ScrollGestureIdleResetMs = 200.0;
    private long _lastScrollSentTick;
    private long _lastScrollEventTick;
    private long _lastPreciseScrollTick;
    private bool _hasPendingScroll;
    private double _pendingScrollDx;
    private double _pendingScrollDy;
    private double _scrollRemPx, _scrollRemPy, _scrollRemLx, _scrollRemLy;

    // Reusable raw input buffer (avoids per-packet GC allocations at 1000Hz+)
    private byte[] _rawBuffer = new byte[128];

    // Low-level keyboard hook for Win key interception while focused
    private nint _kbHookHandle;
    private LowLevelKeyboardProc? _kbHookProc;

    // ── Outgoing input events (wired by DesktopForm to RemoterConnection) ──

    /// <summary>(nx, ny, draggingButtonOrNull)</summary>
    public event Action<double, double, string?>? MouseMove;

    /// <summary>(dx, dy) raw relative deltas when Pointer Lock is active</summary>
    public event Action<int, int>? MouseRelativeMove;

    /// <summary>(button: "left"|"right"|"middle", down, nx, ny)</summary>
    public event Action<string, bool, double, double>? MouseButton;

    /// <summary>(button, nx, ny)</summary>
    public event Action<string, double, double>? MouseDoubleClick;

    /// <summary>(dxNotch, dyNotch, dxPx, dyPx, isPrecise)</summary>
    public event Action<int, int, int, int, bool>? MouseScroll;

    /// <summary>(jsCode, down, modifiers)</summary>
    public event Action<string, bool, string[]>? KeyEvent;

    /// <summary>(committedText) for local IME characters if needed</summary>
#pragma warning disable CS0067
    public event Action<string>? TextInput;
#pragma warning restore CS0067

    /// <summary>Fired when Pointer Lock state changes.</summary>
    public event Action<bool>? PointerLockChanged;

    /// <summary>Fired on F11 or Ctrl+Alt+F.</summary>
    public event Action? ToggleFullscreenRequested;

    public bool Enabled
    {
        get => _enabled;
        set
        {
            _enabled = value;
            if (!value)
            {
                ReleaseAllKeys();
                SetPointerLock(false);
            }
        }
    }

    public bool IsPointerLocked => _pointerLocked;

    public RawInputManager(VideoHostControl host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));

        _moveFlushTimer = new System.Windows.Forms.Timer { Interval = 8 };
        _moveFlushTimer.Tick += (_, _) => FlushPendingMove();

        _scrollFlushTimer = new System.Windows.Forms.Timer { Interval = 8 };
        _scrollFlushTimer.Tick += (_, _) => FlushPendingScroll();

        _host.HandleCreated += OnHostHandleCreated;
        _host.RawInputReceived += OnRawInput;
        _host.MouseWheelReceived += OnMouseWheel;
        _host.KeyMessageReceived += OnKeyMessage;
        _host.FocusLost += OnFocusLost;
        _host.MouseMove += OnControlMouseMove;
        _host.MouseDown += OnControlMouseDown;
        _host.MouseUp += OnControlMouseUp;
        _host.MouseDoubleClick += OnControlMouseDoubleClick;

        if (_host.IsHandleCreated)
        {
            RegisterRawMouse(_host.Handle);
        }

        InstallWinKeyHook();
    }

    public void SetRemoteSize(int width, int height)
    {
        if (width > 0) _remoteWidth = width;
        if (height > 0) _remoteHeight = height;
    }

    /// <summary>
    /// Updates the rendered video content rectangle within VideoHostControl client pixels
    /// so Fit (letterbox), Stretch, and Original (1:1) map cursor coordinates accurately.
    /// </summary>
    public void SetContentRect(Rectangle rect)
    {
        _contentRect = rect;
    }

    /// <summary>
    /// Computes the video content rectangle for a given host size, remote size, and scale mode ("fit", "stretch", "original").
    /// </summary>
    public static Rectangle ComputeContentRect(int hostW, int hostH, int remoteW, int remoteH, string scaleMode)
    {
        if (hostW <= 0 || hostH <= 0) return Rectangle.Empty;
        if (remoteW <= 0 || remoteH <= 0) return new Rectangle(0, 0, hostW, hostH);

        switch (scaleMode)
        {
            case "stretch":
                return new Rectangle(0, 0, hostW, hostH);

            case "original":
            {
                int w = remoteW;
                int h = remoteH;
                int x = (hostW - w) / 2;
                int y = (hostH - h) / 2;
                return new Rectangle(x, y, w, h);
            }

            case "fit":
            default:
            {
                double hostAspect = (double)hostW / hostH;
                double remoteAspect = (double)remoteW / remoteH;
                int w, h;
                if (hostAspect > remoteAspect)
                {
                    h = hostH;
                    w = Math.Max(1, (int)Math.Round(hostH * remoteAspect));
                }
                else
                {
                    w = hostW;
                    h = Math.Max(1, (int)Math.Round(hostW / remoteAspect));
                }
                int x = (hostW - w) / 2;
                int y = (hostH - h) / 2;
                return new Rectangle(x, y, w, h);
            }
        }
    }

    public void SetWindowActive(bool active)
    {
        _windowActive = active;
        if (!active)
        {
            ReleaseAllKeys();
            SetPointerLock(false);
        }
    }

    public void TogglePointerLock() => SetPointerLock(!_pointerLocked);

    public void SetPointerLock(bool locked)
    {
        if (_disposed) return;
        if (locked == _pointerLocked) return;

        if (locked)
        {
            if (!_host.IsHandleCreated || !_enabled) return;
            _host.Focus();
            _pointerLocked = true;
            _host.SuppressSystemCursor = true;
            UpdateClipCursor();
            HideSystemCursor();
        }
        else
        {
            _pointerLocked = false;
            _host.SuppressSystemCursor = false;
            ClipCursor(nint.Zero);
            ShowSystemCursor();
        }

        PointerLockChanged?.Invoke(_pointerLocked);
    }

    public void UpdateClipCursor()
    {
        if (!_pointerLocked || !_host.IsHandleCreated) return;
        Point tl = _host.PointToScreen(Point.Empty);
        var r = new RECT
        {
            Left = tl.X,
            Top = tl.Y,
            Right = tl.X + Math.Max(1, _host.ClientSize.Width),
            Bottom = tl.Y + Math.Max(1, _host.ClientSize.Height),
        };
        ClipCursor(ref r);
    }

    public void ReleaseAllKeys()
    {
        if (_pressedKeys.Count == 0) return;
        foreach (string code in _pressedKeys)
        {
            KeyEvent?.Invoke(code, false, Array.Empty<string>());
        }
        _pressedKeys.Clear();
    }

    // ── RawInput registration & processing ───────────────────────────────

    private void OnHostHandleCreated(object? sender, EventArgs e)
    {
        RegisterRawMouse(_host.Handle);
    }

    private static void RegisterRawMouse(nint hwnd)
    {
        if (hwnd == nint.Zero) return;
        var rid = new RAWINPUTDEVICE[]
        {
            new()
            {
                usUsagePage = HID_USAGE_PAGE_GENERIC,
                usUsage     = HID_USAGE_GENERIC_MOUSE,
                dwFlags     = 0,
                hwndTarget  = hwnd,
            }
        };
        RegisterRawInputDevices(rid, (uint)rid.Length, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
    }

    private void OnRawInput(nint hRawInput)
    {
        if (!_enabled || !_pointerLocked || _disposed) return;

        uint headerSize = (uint)Marshal.SizeOf<RAWINPUTHEADER>();
        uint size = 0;
        if (GetRawInputData(hRawInput, RID_INPUT, null, ref size, headerSize) != 0 || size == 0)
            return;

        if (_rawBuffer.Length < size)
            _rawBuffer = new byte[Math.Max(size, (uint)_rawBuffer.Length * 2)];

        uint read = GetRawInputData(hRawInput, RID_INPUT, _rawBuffer, ref size, headerSize);
        if (read == unchecked((uint)-1) || read < headerSize)
            return;

        ReadOnlySpan<byte> span = _rawBuffer.AsSpan(0, (int)read);
        RAWINPUTHEADER header = MemoryMarshal.Read<RAWINPUTHEADER>(span);
        if (header.dwType != RIM_TYPEMOUSE || read < headerSize + Marshal.SizeOf<RAWMOUSE>())
            return;

        RAWMOUSE mouse = MemoryMarshal.Read<RAWMOUSE>(span.Slice((int)headerSize));

        // Handle raw mouse button transitions in Pointer Lock mode
        ushort bf = mouse.usButtonFlags;
        if ((bf & RI_MOUSE_LEFT_BUTTON_DOWN) != 0)   { _heldButtons |= MouseButtons.Left;   MouseButton?.Invoke("left", true, _curNormX, _curNormY); }
        if ((bf & RI_MOUSE_LEFT_BUTTON_UP) != 0)     { _heldButtons &= ~MouseButtons.Left;  MouseButton?.Invoke("left", false, _curNormX, _curNormY); }
        if ((bf & RI_MOUSE_RIGHT_BUTTON_DOWN) != 0)  { _heldButtons |= MouseButtons.Right;  MouseButton?.Invoke("right", true, _curNormX, _curNormY); }
        if ((bf & RI_MOUSE_RIGHT_BUTTON_UP) != 0)    { _heldButtons &= ~MouseButtons.Right; MouseButton?.Invoke("right", false, _curNormX, _curNormY); }
        if ((bf & RI_MOUSE_MIDDLE_BUTTON_DOWN) != 0) { _heldButtons |= MouseButtons.Middle; MouseButton?.Invoke("middle", true, _curNormX, _curNormY); }
        if ((bf & RI_MOUSE_MIDDLE_BUTTON_UP) != 0)   { _heldButtons &= ~MouseButtons.Middle; MouseButton?.Invoke("middle", false, _curNormX, _curNormY); }

        // Relative delta movement
        if ((mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0 && (mouse.lLastX != 0 || mouse.lLastY != 0))
        {
            int dx = mouse.lLastX;
            int dy = mouse.lLastY;
            MouseRelativeMove?.Invoke(dx, dy);

            _curNormX = Math.Clamp(_curNormX + dx / (double)_remoteWidth, 0.0, 1.0);
            _curNormY = Math.Clamp(_curNormY + dy / (double)_remoteHeight, 0.0, 1.0);
            SendMouseMoveThrottled(_curNormX, _curNormY, ButtonsToDragName(_heldButtons));
        }
    }

    // ── Standard absolute mouse (when not pointer-locked) ────────────────

    private void OnControlMouseMove(object? sender, MouseEventArgs e)
    {
        if (!_enabled || _pointerLocked) return;
        var (nx, ny) = MapClientToNormalized(e.X, e.Y);
        _curNormX = nx;
        _curNormY = ny;
        SendMouseMoveThrottled(nx, ny, ButtonsToDragName(e.Button));
    }

    private void OnControlMouseDown(object? sender, MouseEventArgs e)
    {
        if (!_enabled) return;
        if (!_host.Focused) _host.Focus();
        if (_pointerLocked) return; // handled by RawInput

        var (nx, ny) = MapClientToNormalized(e.X, e.Y);
        _curNormX = nx;
        _curNormY = ny;
        _heldButtons |= e.Button;
        string? btn = MapMouseButton(e.Button);
        if (btn != null)
            MouseButton?.Invoke(btn, true, nx, ny);
    }

    private void OnControlMouseUp(object? sender, MouseEventArgs e)
    {
        if (!_enabled || _pointerLocked) return;
        var (nx, ny) = MapClientToNormalized(e.X, e.Y);
        _curNormX = nx;
        _curNormY = ny;
        _heldButtons &= ~e.Button;
        string? btn = MapMouseButton(e.Button);
        if (btn != null)
            MouseButton?.Invoke(btn, false, nx, ny);
    }

    private void OnControlMouseDoubleClick(object? sender, MouseEventArgs e)
    {
        if (!_enabled || _pointerLocked) return;
        var (nx, ny) = MapClientToNormalized(e.X, e.Y);
        string? btn = MapMouseButton(e.Button);
        if (btn != null)
            MouseDoubleClick?.Invoke(btn, nx, ny);
    }

    private (double nx, double ny) MapClientToNormalized(int clientX, int clientY)
    {
        Rectangle cr = _contentRect;
        if (cr.Width <= 0 || cr.Height <= 0)
        {
            cr = new Rectangle(0, 0, Math.Max(1, _host.ClientSize.Width), Math.Max(1, _host.ClientSize.Height));
        }
        double nx = Math.Clamp((clientX - cr.Left) / (double)cr.Width, 0.0, 1.0);
        double ny = Math.Clamp((clientY - cr.Top) / (double)cr.Height, 0.0, 1.0);
        return (nx, ny);
    }

    private void SendMouseMoveThrottled(double nx, double ny, string? dragging)
    {
        long now = Stopwatch.GetTimestamp();
        double elapsedMs = (now - _lastMoveSentTick) * 1000.0 / Stopwatch.Frequency;
        if (elapsedMs >= MoveThrottleMs)
        {
            _moveFlushTimer.Stop();
            _hasPendingMove = false;
            _lastMoveSentTick = now;
            MouseMove?.Invoke(nx, ny, dragging);
            return;
        }

        _pendingMoveNx = nx;
        _pendingMoveNy = ny;
        _pendingMoveDrag = dragging;
        _hasPendingMove = true;
        if (!_moveFlushTimer.Enabled)
        {
            _moveFlushTimer.Interval = Math.Max(1, (int)Math.Ceiling(MoveThrottleMs - elapsedMs));
            _moveFlushTimer.Start();
        }
    }

    private void FlushPendingMove()
    {
        _moveFlushTimer.Stop();
        if (!_hasPendingMove || !_enabled) return;
        _hasPendingMove = false;
        _lastMoveSentTick = Stopwatch.GetTimestamp();
        MouseMove?.Invoke(_pendingMoveNx, _pendingMoveNy, _pendingMoveDrag);
    }

    // ── Smooth wheel & precision touchpad (120Hz coalescing) ─────────────

    private void OnMouseWheel(nint wParam, nint lParam, bool isHorizontal)
    {
        if (!_enabled) return;

        // Signed 16-bit wheel delta in high word of wParam (120 = 1 standard notch)
        short wheelDelta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
        if (wheelDelta == 0) return;

        long now = Stopwatch.GetTimestamp();
        if (_lastScrollEventTick != 0)
        {
            double idleMs = (now - _lastScrollEventTick) * 1000.0 / Stopwatch.Frequency;
            if (idleMs > ScrollGestureIdleResetMs)
            {
                // Gesture ended — clear stale sub-unit remainders so the next gesture starts cleanly
                _scrollRemPx = _scrollRemPy = _scrollRemLx = _scrollRemLy = 0;
            }
        }
        _lastScrollEventTick = now;

        // Scale to Remoter's 100px = 1 notch convention:
        // Vertical: Win32 +120 = up, Remoter +dy = down -> negate
        // Horizontal: Win32 +120 = right, Remoter +dx = right -> keep sign
        double px = wheelDelta * (100.0 / 120.0);
        double dx = isHorizontal ? px : 0.0;
        double dy = isHorizontal ? 0.0 : -px;

        // UU-Remote precise vs mechanical classification:
        // Precision touchpads emit sub-notch deltas (not multiples of WHEEL_DELTA=120);
        // keep a 60ms sticky window so a fast touchpad swipe that happens to land on 120 stays precise.
        bool subNotch = (Math.Abs((int)wheelDelta) % 120) != 0;
        bool withinSticky = _lastPreciseScrollTick != 0 &&
                            ((now - _lastPreciseScrollTick) * 1000.0 / Stopwatch.Frequency) <= PreciseStickyWindowMs;
        bool isPrecise = subNotch || withinSticky;
        if (subNotch)
        {
            _lastPreciseScrollTick = now;
        }

        if (!isPrecise)
        {
            FlushScrollImmediate(dx, dy, isPrecise: false);
        }
        else
        {
            SendScrollThrottled(dx, dy);
        }
    }

    private void SendScrollThrottled(double dx, double dy)
    {
        _pendingScrollDx += dx;
        _pendingScrollDy += dy;
        _hasPendingScroll = true;

        long now = Stopwatch.GetTimestamp();
        double elapsedMs = (now - _lastScrollSentTick) * 1000.0 / Stopwatch.Frequency;
        if (elapsedMs >= ScrollThrottleMs)
        {
            _scrollFlushTimer.Stop();
            double adx = _pendingScrollDx;
            double ady = _pendingScrollDy;
            _pendingScrollDx = 0;
            _pendingScrollDy = 0;
            _hasPendingScroll = false;
            _lastScrollSentTick = now;
            ApplyAxisLockAndFlush(adx, ady, isPrecise: true);
            return;
        }

        if (!_scrollFlushTimer.Enabled)
        {
            _scrollFlushTimer.Interval = Math.Max(1, (int)Math.Ceiling(ScrollThrottleMs - elapsedMs));
            _scrollFlushTimer.Start();
        }
    }

    private void FlushPendingScroll()
    {
        _scrollFlushTimer.Stop();
        if (!_hasPendingScroll || !_enabled) return;
        double adx = _pendingScrollDx;
        double ady = _pendingScrollDy;
        _pendingScrollDx = 0;
        _pendingScrollDy = 0;
        _hasPendingScroll = false;
        _lastScrollSentTick = Stopwatch.GetTimestamp();
        ApplyAxisLockAndFlush(adx, ady, isPrecise: true);
    }

    private void ApplyAxisLockAndFlush(double dx, double dy, bool isPrecise)
    {
        // Soft axis lock: suppress minor perpendicular drift when one axis dominates 3:1
        double ax = Math.Abs(dx);
        double ay = Math.Abs(dy);
        if (ay > ax * 3.0) dx = 0;
        else if (ax > ay * 3.0) dy = 0;

        if (dx == 0 && dy == 0) return;
        FlushScrollImmediate(dx, dy, isPrecise);
    }

    private void FlushScrollImmediate(double dxPx, double dyPx, bool isPrecise)
    {
        _scrollRemPx += dxPx;
        _scrollRemPy += dyPx;
        _scrollRemLx += dxPx / 100.0;
        _scrollRemLy += dyPx / 100.0;

        int px = (int)Math.Truncate(_scrollRemPx);
        int py = (int)Math.Truncate(_scrollRemPy);
        int lx = (int)Math.Truncate(_scrollRemLx);
        int ly = (int)Math.Truncate(_scrollRemLy);

        _scrollRemPx -= px;
        _scrollRemPy -= py;
        _scrollRemLx -= lx;
        _scrollRemLy -= ly;

        if (px != 0 || py != 0 || lx != 0 || ly != 0)
        {
            MouseScroll?.Invoke(lx, ly, px, py, isPrecise);
        }
    }

    // ── Keyboard & local hotkeys ─────────────────────────────────────────

    private bool OnKeyMessage(bool down, nint wParam, nint lParam)
    {
        if (!_enabled) return false;

        string? code = KeyCodeMapper.MapToJsCode(wParam, lParam);
        if (code == null) return false;

        // Check local client shortcuts before forwarding to remote
        if (down)
        {
            bool ctrl = KeyCodeMapper.IsKeyDown(0x11);
            bool alt  = KeyCodeMapper.IsKeyDown(0x12);

            // Ctrl + Alt + Enter -> toggle Pointer Lock (Game Mouse mode)
            if (ctrl && alt && (code == "Enter" || code == "NumpadEnter"))
            {
                ReleaseAllKeys();
                TogglePointerLock();
                return true;
            }

            // F11 or Ctrl + Alt + F -> toggle Fullscreen
            if (code == "F11" || (ctrl && alt && code == "KeyF"))
            {
                ReleaseAllKeys();
                ToggleFullscreenRequested?.Invoke();
                return true;
            }

            // CapsLock: send down+up unconditionally (matches Remoter-Client)
            if (code == "CapsLock")
            {
                KeyEvent?.Invoke("CapsLock", true, Array.Empty<string>());
                KeyEvent?.Invoke("CapsLock", false, Array.Empty<string>());
                return true;
            }

            _pressedKeys.Add(code);
            KeyEvent?.Invoke(code, true, KeyCodeMapper.CollectModifiers());
            return true;
        }
        else
        {
            if (code == "CapsLock") return true;
            if (!_pressedKeys.Remove(code)) return true;
            KeyEvent?.Invoke(code, false, KeyCodeMapper.CollectModifiers());
            return true;
        }
    }

    private void OnFocusLost()
    {
        ReleaseAllKeys();
        SetPointerLock(false);
    }

    // ── Win key low-level hook (intercepts Start menu while focused) ─────

    private void InstallWinKeyHook()
    {
        _kbHookProc = LowLevelKeyboardCallback;
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        nint hMod = curModule != null ? GetModuleHandleW(curModule.ModuleName) : nint.Zero;
        _kbHookHandle = SetWindowsHookExW(WH_KEYBOARD_LL, _kbHookProc, hMod, 0);
    }

    private nint LowLevelKeyboardCallback(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0 && _enabled && _windowActive && _host.Focused)
        {
            int msg = (int)wParam;
            if (msg == WM_KEYDOWN || msg == WM_KEYUP || msg == WM_SYSKEYDOWN || msg == WM_SYSKEYUP)
            {
                var kbd = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                if (kbd.vkCode == VK_LWIN || kbd.vkCode == VK_RWIN)
                {
                    bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
                    string code = kbd.vkCode == VK_RWIN ? "MetaRight" : "MetaLeft";
                    if (down)
                    {
                        _pressedKeys.Add(code);
                        KeyEvent?.Invoke(code, true, KeyCodeMapper.CollectModifiers());
                    }
                    else
                    {
                        _pressedKeys.Remove(code);
                        KeyEvent?.Invoke(code, false, KeyCodeMapper.CollectModifiers());
                    }
                    return (nint)1; // swallow so local Windows Start menu does not open
                }
            }
        }
        return CallNextHookEx(_kbHookHandle, nCode, wParam, lParam);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private void HideSystemCursor()
    {
        if (_cursorHidden) return;
        _cursorHidden = true;
        while (ShowCursor(false) >= 0) { }
    }

    private void ShowSystemCursor()
    {
        if (!_cursorHidden) return;
        _cursorHidden = false;
        while (ShowCursor(true) < 0) { }
    }

    private static string? MapMouseButton(MouseButtons b) => b switch
    {
        MouseButtons.Left   => "left",
        MouseButtons.Right  => "right",
        MouseButtons.Middle => "middle",
        _                   => null,
    };

    private static string? ButtonsToDragName(MouseButtons buttons)
    {
        if ((buttons & MouseButtons.Left) != 0)   return "left";
        if ((buttons & MouseButtons.Right) != 0)  return "right";
        if ((buttons & MouseButtons.Middle) != 0) return "middle";
        return null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        SetPointerLock(false);
        ReleaseAllKeys();

        if (_kbHookHandle != nint.Zero)
        {
            UnhookWindowsHookEx(_kbHookHandle);
            _kbHookHandle = nint.Zero;
        }

        _moveFlushTimer.Dispose();
        _scrollFlushTimer.Dispose();

        _host.HandleCreated -= OnHostHandleCreated;
        _host.RawInputReceived -= OnRawInput;
        _host.MouseWheelReceived -= OnMouseWheel;
        _host.KeyMessageReceived -= OnKeyMessage;
        _host.FocusLost -= OnFocusLost;
        _host.MouseMove -= OnControlMouseMove;
        _host.MouseDown -= OnControlMouseDown;
        _host.MouseUp -= OnControlMouseUp;
        _host.MouseDoubleClick -= OnControlMouseDoubleClick;
    }

    // ── Win32 P/Invoke ───────────────────────────────────────────────────

    private delegate nint LowLevelKeyboardProc(int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] pRawInputDevices, uint uiNumDevices, uint cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(nint hRawInput, uint uiCommand, [Out] byte[]? pData, ref uint pcbSize, uint cbSizeHeader);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClipCursor(ref RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClipCursor(nint lpRect);

    [DllImport("user32.dll")]
    private static extern int ShowCursor([MarshalAs(UnmanagedType.Bool)] bool bShow);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookExW(int idHook, LowLevelKeyboardProc lpfn, nint hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(nint hhk);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE
    {
        public ushort usUsagePage;
        public ushort usUsage;
        public uint   dwFlags;
        public nint   hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER
    {
        public uint dwType;
        public uint dwSize;
        public nint hDevice;
        public nint wParam;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct RAWMOUSE
    {
        [FieldOffset(0)]  public ushort usFlags;
        [FieldOffset(4)]  public uint   ulButtons;
        [FieldOffset(4)]  public ushort usButtonFlags;
        [FieldOffset(6)]  public ushort usButtonData;
        [FieldOffset(8)]  public uint   ulRawButtons;
        [FieldOffset(12)] public int    lLastX;
        [FieldOffset(16)] public int    lLastY;
        [FieldOffset(20)] public uint   ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }
}
