using System.Drawing;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Lightweight native Win32 viewport control (CS_OWNDC, WS_CLIPCHILDREN, zero GDI erase flicker)
/// that exposes its HWND to D3D11Renderer, routes raw Win32 input messages, and accepts file drag-and-drop.
/// </summary>
public sealed class VideoHostControl : Control
{
    private const int CS_OWNDC          = 0x0020;
    private const int WS_CLIPCHILDREN   = 0x02000000;

    private const int WM_SIZE           = 0x0005;
    private const int WM_KILLFOCUS      = 0x0008;
    private const int WM_SETCURSOR      = 0x0020;
    private const int WM_INPUT          = 0x00FF;
    private const int WM_KEYDOWN        = 0x0100;
    private const int WM_KEYUP          = 0x0101;
    private const int WM_CHAR           = 0x0102;
    private const int WM_SYSKEYDOWN     = 0x0104;
    private const int WM_SYSKEYUP       = 0x0105;
    private const int WM_MOUSEWHEEL     = 0x020A;
    private const int WM_MOUSEHWHEEL    = 0x020E;
    private const int WM_IME_CHAR       = 0x0286;
    private const int WM_DPICHANGED     = 0x02E0;

    /// <summary>True once D3D11 swapchain is actively presenting frames; suppresses GDI fallback clear.</summary>
    public bool D3D11Active { get; set; }

    /// <summary>When true, WM_SETCURSOR is suppressed so the OS cursor stays hidden during Pointer Lock.</summary>
    public bool SuppressSystemCursor { get; set; }

    /// <summary>Fired on WM_INPUT with raw HRAWINPUT (lParam).</summary>
    public event Action<nint>? RawInputReceived;

    /// <summary>Fired on WM_MOUSEWHEEL / WM_MOUSEHWHEEL (wParam, lParam, isHorizontal).</summary>
    public event Action<nint, nint, bool>? MouseWheelReceived;

    /// <summary>
    /// Fired on WM_KEYDOWN/WM_KEYUP/WM_SYSKEYDOWN/WM_SYSKEYUP.
    /// Return true to mark the message handled (suppresses default Win32 menu beep on Alt/F10).
    /// </summary>
    public event Func<bool, nint, nint, bool>? KeyMessageReceived;

    /// <summary>Fired on WM_CHAR / WM_IME_CHAR for committed local IME / Unicode characters.</summary>
    public event Action<char>? CharReceived;

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
                if (KeyMessageReceived?.Invoke(true, m.WParam, m.LParam) == true)
                {
                    m.Result = nint.Zero;
                    return;
                }
                break;

            case WM_KEYUP:
            case WM_SYSKEYUP:
                if (KeyMessageReceived?.Invoke(false, m.WParam, m.LParam) == true)
                {
                    m.Result = nint.Zero;
                    return;
                }
                break;

            case WM_CHAR:
            case WM_IME_CHAR:
                char ch = (char)(m.WParam & 0xFFFF);
                if (!char.IsControl(ch))
                {
                    CharReceived?.Invoke(ch);
                }
                break;

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
}
