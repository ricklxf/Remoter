using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Lightweight native Win32 viewport control (CS_OWNDC, WS_CLIPCHILDREN, zero GDI erase flicker)
/// that exposes its HWND to D3D11Renderer, routes raw Win32 input messages, handles local Windows IME
/// composition/commit via imm32.dll, and accepts file drag-and-drop.
/// </summary>
public sealed class VideoHostControl : Control
{
    private const int CS_OWNDC          = 0x0020;
    private const int WS_CLIPCHILDREN   = 0x02000000;

    private const int WM_SIZE                  = 0x0005;
    private const int WM_KILLFOCUS             = 0x0008;
    private const int WM_SETCURSOR             = 0x0020;
    private const int WM_INPUT                 = 0x00FF;
    private const int WM_KEYDOWN               = 0x0100;
    private const int WM_KEYUP                 = 0x0101;
    private const int WM_CHAR                  = 0x0102;
    private const int WM_SYSKEYDOWN            = 0x0104;
    private const int WM_SYSKEYUP              = 0x0105;
    private const int WM_IME_STARTCOMPOSITION  = 0x010D;
    private const int WM_IME_ENDCOMPOSITION    = 0x010E;
    private const int WM_IME_COMPOSITION       = 0x010F;
    private const int WM_MOUSEWHEEL            = 0x020A;
    private const int WM_MOUSEHWHEEL           = 0x020E;
    private const int WM_IME_CHAR              = 0x0286;
    private const int WM_DPICHANGED            = 0x02E0;

    private const int VK_PROCESSKEY            = 0xE5;
    private const int GCS_COMPSTR              = 0x0008;
    private const int GCS_RESULTSTR            = 0x0800;
    private const int CFS_POINT                = 0x0002;
    private const int CFS_CANDIDATEPOS         = 0x0040;

    private int _suppressImeCharCount;
    private long _suppressImeCharTick;

    /// <summary>True once D3D11 swapchain is actively presenting frames; suppresses GDI fallback clear.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool D3D11Active { get; set; }

    /// <summary>When true, WM_SETCURSOR is suppressed so the OS cursor stays hidden during Pointer Lock.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool SuppressSystemCursor { get; set; }

    /// <summary>True while local Windows IME composition is active.</summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool IsImeComposing { get; private set; }

    /// <summary>
    /// Optional provider returning the IME composition echo label's bounds in this control's client coordinates
    /// when visible, so the OS IME candidate window anchors cleanly below it.
    /// </summary>
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Func<Rectangle?>? ImeEchoBoundsProvider { get; set; }

    /// <summary>Fired on WM_INPUT with raw HRAWINPUT (lParam).</summary>
    public event Action<nint>? RawInputReceived;

    /// <summary>Fired on WM_MOUSEWHEEL / WM_MOUSEHWHEEL (wParam, lParam, isHorizontal).</summary>
    public event Action<nint, nint, bool>? MouseWheelReceived;

    /// <summary>
    /// Fired on WM_KEYDOWN/WM_KEYUP/WM_SYSKEYDOWN/WM_SYSKEYUP.
    /// Return true to mark the message handled (suppresses default Win32 menu beep on Alt/F10).
    /// </summary>
    public event Func<bool, nint, nint, bool>? KeyMessageReceived;

    /// <summary>Fired on WM_CHAR / WM_IME_CHAR for committed non-ASCII characters outside composition.</summary>
    public event Action<char>? CharReceived;

    /// <summary>Fired when the local IME composition text updates (empty string hides the echo overlay).</summary>
    public event Action<string>? ImeCompositionChanged;

    /// <summary>Fired when local Windows IME commits Unicode/CJK text (sent to host via text_input).</summary>
    public event Action<string>? ImeTextCommitted;

    /// <summary>Fired on WM_SIZE with new client width and height in physical pixels.</summary>
    public event Action<int, int>? ViewportResized;

    /// <summary>Fired on WM_DPICHANGED with new DPI (X, Y).</summary>
    public event Action<int, int>? DpiChangedEvent;

    /// <summary>Fired on WM_KILLFOCUS so pressed keys &amp; pointer lock can be cleanly released.</summary>
    public event Action? FocusLost;

    /// <summary>Fired when the user drops one or more files onto the remote desktop viewport.</summary>
    public event Action<string[]>? FilesDropped;

    public VideoHostControl()
    {
        SetStyle(
            ControlStyles.Opaque |
            ControlStyles.UserPaint |
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.Selectable,
            true);
        DoubleBuffered = false;
        TabStop = true;
        AllowDrop = true;
        BackColor = DarkTheme.VideoBg;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ClassStyle |= CS_OWNDC;
            cp.Style |= WS_CLIPCHILDREN;
            return cp;
        }
    }

    protected override bool IsInputKey(Keys keyData)
    {
        // Route Tab, Arrow keys, Enter, Escape, Alt, etc. directly to WndProc instead of WinForms dialog nav
        return true;
    }

    protected override void OnPaintBackground(PaintEventArgs pevent)
    {
        // Never erase with GDI — prevents flicker over Direct3D 11 flip-model swapchain
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (!D3D11Active)
        {
            using var brush = new SolidBrush(DarkTheme.VideoBg);
            e.Graphics.FillRectangle(brush, ClientRectangle);
        }
    }

    protected override void OnDragEnter(DragEventArgs drgevent)
    {
        if (drgevent.Data?.GetDataPresent(DataFormats.FileDrop) == true)
        {
            drgevent.Effect = DragDropEffects.Copy;
        }
        else
        {
            drgevent.Effect = DragDropEffects.None;
        }
        base.OnDragEnter(drgevent);
    }

    protected override void OnDragDrop(DragEventArgs drgevent)
    {
        if (drgevent.Data?.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0)
        {
            FilesDropped?.Invoke(files);
        }
        base.OnDragDrop(drgevent);
    }

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case WM_INPUT:
                RawInputReceived?.Invoke(m.LParam);
                base.WndProc(ref m);
                return;

            case WM_MOUSEWHEEL:
                MouseWheelReceived?.Invoke(m.WParam, m.LParam, false);
                m.Result = nint.Zero;
                return;

            case WM_MOUSEHWHEEL:
                MouseWheelReceived?.Invoke(m.WParam, m.LParam, true);
                m.Result = nint.Zero;
                return;

            case WM_KEYDOWN:
            case WM_SYSKEYDOWN:
            {
                int vkDown = (int)(m.WParam & 0xFFFF);
                if (vkDown == VK_PROCESSKEY || IsImeComposing)
                {
                    // Let Windows IME compose / select candidates locally without leaking raw keys
                    base.WndProc(ref m);
                    return;
                }
                if (KeyMessageReceived?.Invoke(true, m.WParam, m.LParam) == true)
                {
                    m.Result = nint.Zero;
                    return;
                }
                break;
            }

            case WM_KEYUP:
            case WM_SYSKEYUP:
            {
                int vkUp = (int)(m.WParam & 0xFFFF);
                if (vkUp == VK_PROCESSKEY || IsImeComposing)
                {
                    base.WndProc(ref m);
                    return;
                }
                if (KeyMessageReceived?.Invoke(false, m.WParam, m.LParam) == true)
                {
                    m.Result = nint.Zero;
                    return;
                }
                break;
            }

            case WM_IME_STARTCOMPOSITION:
                IsImeComposing = true;
                PositionImeWindow();
                ImeCompositionChanged?.Invoke("");
                base.WndProc(ref m);
                return;

            case WM_IME_COMPOSITION:
            {
                int flags = (int)m.LParam;
                bool handledResult = false;

                if ((flags & GCS_COMPSTR) != 0)
                {
                    string comp = ReadImeString(GCS_COMPSTR);
                    ImeCompositionChanged?.Invoke(comp);
                    PositionImeWindow();
                }

                if ((flags & GCS_RESULTSTR) != 0)
                {
                    string result = ReadImeString(GCS_RESULTSTR);
                    if (!string.IsNullOrEmpty(result))
                    {
                        _suppressImeCharCount = result.Length;
                        _suppressImeCharTick = Environment.TickCount64;
                        ImeTextCommitted?.Invoke(result);
                        handledResult = true;
                    }
                    ImeCompositionChanged?.Invoke("");
                }

                if (handledResult)
                {
                    // Suppress DefWindowProc so WM_IME_CHAR / WM_CHAR won't double-send this result
                    m.Result = nint.Zero;
                    return;
                }
                base.WndProc(ref m);
                return;
            }

            case WM_IME_ENDCOMPOSITION:
                IsImeComposing = false;
                ImeCompositionChanged?.Invoke("");
                base.WndProc(ref m);
                return;

            case WM_CHAR:
            case WM_IME_CHAR:
            {
                char ch = (char)(m.WParam & 0xFFFF);
                if (_suppressImeCharCount > 0 && Environment.TickCount64 - _suppressImeCharTick < 100)
                {
                    _suppressImeCharCount--;
                    m.Result = nint.Zero;
                    return;
                }
                _suppressImeCharCount = 0;

                // Only forward non-ASCII characters (e.g. Chinese punctuation typed outside composition);
                // plain ASCII keys are already forwarded via WM_KEYDOWN so sending them here would double-type.
                if (!char.IsControl(ch) && ch > 0x7F)
                {
                    CharReceived?.Invoke(ch);
                    ImeTextCommitted?.Invoke(ch.ToString());
                }
                m.Result = nint.Zero;
                return;
            }

            case WM_SIZE:
                base.WndProc(ref m);
                int w = (int)(m.LParam & 0xFFFF);
                int h = (int)((m.LParam >> 16) & 0xFFFF);
                if (w > 0 && h > 0)
                {
                    ViewportResized?.Invoke(w, h);
                }
                return;

            case WM_DPICHANGED:
                int dpiX = (int)(m.WParam & 0xFFFF);
                int dpiY = (int)((m.WParam >> 16) & 0xFFFF);
                DpiChangedEvent?.Invoke(dpiX, dpiY);
                break;

            case WM_KILLFOCUS:
                if (IsImeComposing)
                {
                    IsImeComposing = false;
                    ImeCompositionChanged?.Invoke("");
                }
                FocusLost?.Invoke();
                break;

            case WM_SETCURSOR:
                if (SuppressSystemCursor)
                {
                    m.Result = (nint)1;
                    return;
                }
                break;
        }

        base.WndProc(ref m);
    }

    // ── Win32 IMM32 Helpers ──────────────────────────────────────────────

    private string ReadImeString(int dwIndex)
    {
        if (!IsHandleCreated) return "";
        nint hImc = ImmGetContext(Handle);
        if (hImc == nint.Zero) return "";
        try
        {
            int byteLen = ImmGetCompositionStringW(hImc, dwIndex, null, 0);
            if (byteLen <= 0) return "";
            byte[] buf = new byte[byteLen];
            int read = ImmGetCompositionStringW(hImc, dwIndex, buf, byteLen);
            if (read <= 0) return "";
            return Encoding.Unicode.GetString(buf, 0, read);
        }
        finally
        {
            ImmReleaseContext(Handle, hImc);
        }
    }

    public void PositionImeWindow()
    {
        if (!IsHandleCreated) return;
        nint hImc = ImmGetContext(Handle);
        if (hImc == nint.Zero) return;
        try
        {
            double scale = Math.Max(1.0, DeviceDpi / 96.0);
            int minPad = (int)Math.Round(16 * scale);
            int gap = (int)Math.Round(2 * scale);
            int bottomClearance = (int)Math.Round(120 * scale);
            int maxY = Math.Max(minPad, ClientSize.Height - minPad);

            int x;
            int y;
            Rectangle? echoBounds = ImeEchoBoundsProvider?.Invoke();
            if (echoBounds is Rectangle rect && rect.Width > 0 && rect.Height > 0)
            {
                x = Math.Max(minPad, rect.Left);
                y = Math.Clamp(rect.Bottom + gap, minPad, maxY);
            }
            else
            {
                x = Math.Max(minPad, ClientSize.Width / 2 - (int)Math.Round(60 * scale));
                y = Math.Clamp(ClientSize.Height - bottomClearance + gap, minPad, maxY);
            }

            var pt = new POINT { X = x, Y = y };
            var compForm = new COMPOSITIONFORM
            {
                dwStyle = CFS_POINT,
                ptCurrentPos = pt,
            };
            ImmSetCompositionWindow(hImc, ref compForm);

            var candForm = new CANDIDATEFORM
            {
                dwIndex = 0,
                dwStyle = CFS_CANDIDATEPOS,
                ptCurrentPos = pt,
            };
            ImmSetCandidateWindow(hImc, ref candForm);
        }
        finally
        {
            ImmReleaseContext(Handle, hImc);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct COMPOSITIONFORM
    {
        public int dwStyle;
        public POINT ptCurrentPos;
        public RECT rcArea;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CANDIDATEFORM
    {
        public int dwIndex;
        public int dwStyle;
        public POINT ptCurrentPos;
        public RECT rcArea;
    }

    [DllImport("imm32.dll")]
    private static extern nint ImmGetContext(nint hWnd);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ImmReleaseContext(nint hWnd, nint hIMC);

    [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
    private static extern int ImmGetCompositionStringW(nint hIMC, int dwIndex, byte[]? lpBuf, int dwBufLen);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ImmSetCandidateWindow(nint hIMC, ref CANDIDATEFORM lpCandidate);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ImmSetCompositionWindow(nint hIMC, ref COMPOSITIONFORM lpCompForm);
}
