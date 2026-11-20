using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// UU-style translucent black bottom-right performance HUD overlay (matching Remoter-MacClient's
/// StatsHudOverlayView and UURemote's NetDetailView).
/// Rendered as an owned per-pixel-alpha layered window (WS_EX_LAYERED | WS_EX_TRANSPARENT |
/// WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) via UpdateLayeredWindow so it composites cleanly over the
/// D3D11 DXGI Flip-Model SwapChain, is 100% click-through, and never steals focus.
/// </summary>
public sealed class StatsHudOverlay : Form
{
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOOLWINDOW  = 0x00000080;
    private const int WS_EX_LAYERED     = 0x00080000;
    private const int WS_EX_NOACTIVATE  = 0x08000000;

    private const int WM_MOUSEACTIVATE  = 0x0021;
    private const int MA_NOACTIVATE     = 3;
    private const int WM_NCHITTEST      = 0x0084;
    private const int HTTRANSPARENT     = -1;

    private const uint SWP_NOSIZE       = 0x0001;
    private const uint SWP_NOZORDER     = 0x0004;
    private const uint SWP_NOACTIVATE   = 0x0010;

    private const int ULW_ALPHA         = 0x00000002;
    private const byte AC_SRC_OVER      = 0x00;
    private const byte AC_SRC_ALPHA     = 0x01;

    private static readonly Color BackgroundColor  = Color.FromArgb(102, 0, 0, 0);        // 0.40 alpha pure black (no border)
    private static readonly Color DefaultTextColor = Color.FromArgb(210, 255, 255, 255);  // ~0.82 alpha white
    private static readonly Color White85Color     = Color.FromArgb(217, 255, 255, 255);  // 0.85 alpha white
    private static readonly Color White72Color     = Color.FromArgb(184, 255, 255, 255);  // 0.72 alpha white
    private static readonly Color MutedTextColor   = Color.FromArgb(140, 255, 255, 255);  // ~0.55 alpha white
    private static readonly Color SeparatorColor   = Color.FromArgb(140, 255, 255, 255);  // ~0.55 alpha white
    private static readonly Color GoodColor        = Color.FromArgb(255, 52, 211, 153);   // #34D399 teal/green
    private static readonly Color WarningColor     = Color.FromArgb(255, 245, 158, 11);   // #F59E0B amber
    private static readonly Color DangerColor      = Color.FromArgb(255, 239, 68, 68);    // #EF4444 red

    private static readonly string PreferredFontFamily = ResolveMonospaceFamily();

    private readonly Form _ownerForm;
    private readonly StringFormat _stringFormat;
    private readonly List<HudSegment[]> _lines = new(5);

    private Font? _cachedFont;
    private float _lastScale;
    private Size _hudSize;
    private bool _hudEnabled = true;

    private readonly record struct HudSegment(string Text, Color Color);

    public StatsHudOverlay(Form ownerForm)
    {
        _ownerForm = ownerForm ?? throw new ArgumentNullException(nameof(ownerForm));
        Owner = ownerForm;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        Enabled = false;

        _stringFormat = (StringFormat)StringFormat.GenericTypographic.Clone();
        _stringFormat.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;

        SetPlaceholderLines();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCHITTEST)
        {
            m.Result = (nint)HTTRANSPARENT;
            return;
        }
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = (nint)MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }

    public void SetHudVisible(bool visible)
    {
        _hudEnabled = visible;
        if (IsDisposed) return;

        if (!_hudEnabled)
        {
            if (Visible) Hide();
            return;
        }

        RenderAndApply();
    }

    public void UpdateStats(
        double fps,
        double bitrateMbps,
        int rttMs,
        string codec,
        bool hardwareDecode,
        double decodeMs = 0,
        string? transport = null)
    {
        if (IsDisposed) return;

        _lines.Clear();

        // Line 1: <transport> · <codec> <HW/SW> (or <codec> <HW/SW> when transport empty)
        string codecLabel = string.IsNullOrWhiteSpace(codec) ? "H.264" : codec.Trim().ToUpperInvariant();
        string hwTag = hardwareDecode ? "HW" : "SW";
        Color hwColor = hardwareDecode ? GoodColor : WarningColor;

        if (!string.IsNullOrWhiteSpace(transport))
        {
            _lines.Add(new[]
            {
                new HudSegment(transport.Trim(), DefaultTextColor),
                new HudSegment(" · ", SeparatorColor),
                new HudSegment(codecLabel + " ", DefaultTextColor),
                new HudSegment(hwTag, hwColor),
            });
        }
        else
        {
            _lines.Add(new[]
            {
                new HudSegment(codecLabel + " ", DefaultTextColor),
                new HudSegment(hwTag, hwColor),
            });
        }

        // Line 2: <fps> fps (< 15 #EF4444, < 25 #F59E0B, else white@0.85)
        int fpsRounded = (int)Math.Round(fps);
        Color fpsColor = fps <= 0
            ? MutedTextColor
            : fps < 15
                ? DangerColor
                : fps < 25
                    ? WarningColor
                    : White85Color;
        _lines.Add(new[] { new HudSegment($"{fpsRounded} fps", fpsColor) });

        // Line 3: <mbps> Mbps
        _lines.Add(new[]
        {
            new HudSegment(
                string.Format(CultureInfo.InvariantCulture, "{0:F1} Mbps", bitrateMbps),
                DefaultTextColor),
        });

        // Line 4: <rtt> ms (< 50 #34D399, 50-99 white@0.85, 100-150 #F59E0B, > 150 #EF4444)
        if (rttMs >= 0)
        {
            Color rttColor = rttMs < 50
                ? GoodColor
                : rttMs < 100
                    ? White85Color
                    : rttMs <= 150
                        ? WarningColor
                        : DangerColor;
            _lines.Add(new[] { new HudSegment($"{rttMs} ms", rttColor) });
        }
        else
        {
            _lines.Add(new[] { new HudSegment("-- ms", MutedTextColor) });
        }

        // Line 5 (when decodeMs > 0): dec <decodeMs> ms (1 decimal place, white@0.72)
        if (decodeMs > 0)
        {
            _lines.Add(new[]
            {
                new HudSegment(
                    string.Format(CultureInfo.InvariantCulture, "dec {0:F1} ms", decodeMs),
                    White72Color),
            });
        }

        if (_hudEnabled)
        {
            RenderAndApply();
        }
    }

    public void UpdatePosition()
    {
        if (IsDisposed || _ownerForm.IsDisposed || !_ownerForm.IsHandleCreated) return;

        if (!_hudEnabled || !_ownerForm.Visible || _ownerForm.WindowState == FormWindowState.Minimized)
        {
            if (Visible) Hide();
            return;
        }

        float scale = GetScale();
        if (!Visible || _hudSize.IsEmpty || Math.Abs(scale - _lastScale) > 0.01f)
        {
            RenderAndApply();
            return;
        }

        if (!TryComputeScreenLocation(_hudSize, scale, out Point pos)) return;
        SetWindowPos(Handle, nint.Zero, pos.X, pos.Y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private void SetPlaceholderLines()
    {
        _lines.Clear();
        _lines.Add(new[] { new HudSegment("-- fps", MutedTextColor) });
        _lines.Add(new[] { new HudSegment("0.0 Mbps", MutedTextColor) });
        _lines.Add(new[] { new HudSegment("-- ms", MutedTextColor) });
    }

    private float GetScale()
    {
        int dpi = _ownerForm.IsHandleCreated ? _ownerForm.DeviceDpi : 96;
        return Math.Max(1.0f, dpi / 96.0f);
    }

    private Font GetOrCreateFont(float scale)
    {
        if (_cachedFont != null && Math.Abs(scale - _lastScale) <= 0.01f)
        {
            return _cachedFont;
        }

        _cachedFont?.Dispose();
        _lastScale = scale;
        float fontPx = 12.0f * scale; // 9pt at 96 DPI
        _cachedFont = new Font(PreferredFontFamily, fontPx, FontStyle.Bold, GraphicsUnit.Pixel);
        return _cachedFont;
    }

    private bool TryComputeScreenLocation(Size hudSize, float scale, out Point location)
    {
        Size clientSize = _ownerForm.ClientSize;
        if (clientSize.Width <= 0 || clientSize.Height <= 0)
        {
            location = Point.Empty;
            return false;
        }

        Point clientTopLeft = _ownerForm.PointToScreen(Point.Empty);
        int inset = (int)Math.Round(10 * scale);
        int x = clientTopLeft.X + Math.Max(0, clientSize.Width - hudSize.Width - inset);
        int y = clientTopLeft.Y + Math.Max(0, clientSize.Height - hudSize.Height - inset);
        location = new Point(x, y);
        return true;
    }

    private void RenderAndApply()
    {
        if (IsDisposed || _ownerForm.IsDisposed || !_ownerForm.IsHandleCreated) return;

        if (!_hudEnabled || !_ownerForm.Visible || _ownerForm.WindowState == FormWindowState.Minimized)
        {
            if (Visible) Hide();
            return;
        }

        if (_ownerForm.ClientSize.Width <= 0 || _ownerForm.ClientSize.Height <= 0) return;

        if (!Visible)
        {
            Show();
        }
        if (!IsHandleCreated) return;

        float scale = GetScale();
        Font font = GetOrCreateFont(scale);
        int padX = (int)Math.Round(8 * scale);
        int padY = (int)Math.Round(5 * scale);
        int minWidth = (int)Math.Round(96 * scale);
        float radius = 4.0f * scale;
        float lineGap = 2.0f * scale;

        int lineCount = _lines.Count;
        float[][] segWidths = new float[lineCount][];
        float maxLineW = 0f;
        float lineHeight = 0f;

        using (var measureBmp = new Bitmap(1, 1, PixelFormat.Format32bppPArgb))
        using (var mg = Graphics.FromImage(measureBmp))
        {
            mg.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            lineHeight = font.GetHeight(mg);

            for (int row = 0; row < lineCount; row++)
            {
                HudSegment[] line = _lines[row];
                float[] widths = new float[line.Length];
                float rowW = 0f;
                for (int i = 0; i < line.Length; i++)
                {
                    SizeF sz = mg.MeasureString(line[i].Text, font, PointF.Empty, _stringFormat);
                    widths[i] = sz.Width;
                    rowW += sz.Width;
                    if (sz.Height > lineHeight) lineHeight = sz.Height;
                }
                segWidths[row] = widths;
                if (rowW > maxLineW) maxLineW = rowW;
            }
        }

        float totalTextH = lineCount > 0
            ? lineCount * lineHeight + (lineCount - 1) * lineGap
            : lineHeight;

        int width = Math.Max(minWidth, padX * 2 + (int)Math.Ceiling(maxLineW) + 2);
        int height = Math.Max(1, padY * 2 + (int)Math.Ceiling(totalTextH));
        _hudSize = new Size(width, height);

        if (!TryComputeScreenLocation(_hudSize, scale, out Point screenPos)) return;

        using var bmp = new Bitmap(width, height, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            var bgRect = new RectangleF(0f, 0f, width, height);
            using GraphicsPath path = CreateRoundedRectPath(bgRect, radius);
            using var bgBrush = new SolidBrush(BackgroundColor);
            g.FillPath(bgBrush, path);

            float drawY = padY;
            for (int row = 0; row < lineCount; row++)
            {
                HudSegment[] line = _lines[row];
                float[] widths = segWidths[row];
                float drawX = padX;
                for (int i = 0; i < line.Length; i++)
                {
                    using var textBrush = new SolidBrush(line[i].Color);
                    g.DrawString(line[i].Text, font, textBrush, drawX, drawY, _stringFormat);
                    drawX += widths[i];
                }
                drawY += lineHeight + lineGap;
            }
        }

        ApplyLayeredBitmap(bmp, screenPos);
    }

    private void ApplyLayeredBitmap(Bitmap bmp, Point screenLocation)
    {
        nint screenDc = GetDC(nint.Zero);
        if (screenDc == nint.Zero) return;

        nint memDc = nint.Zero;
        nint hBitmap = nint.Zero;
        nint oldBitmap = nint.Zero;
        try
        {
            memDc = CreateCompatibleDC(screenDc);
            if (memDc == nint.Zero) return;

            hBitmap = bmp.GetHbitmap(Color.FromArgb(0));
            if (hBitmap == nint.Zero) return;

            oldBitmap = SelectObject(memDc, hBitmap);

            var size = new SIZE { CX = bmp.Width, CY = bmp.Height };
            var src = new POINT { X = 0, Y = 0 };
            var dst = new POINT { X = screenLocation.X, Y = screenLocation.Y };
            var blend = new BLENDFUNCTION
            {
                BlendOp = AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = AC_SRC_ALPHA,
            };

            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            if (oldBitmap != nint.Zero && memDc != nint.Zero)
                SelectObject(memDc, oldBitmap);
            if (hBitmap != nint.Zero)
                DeleteObject(hBitmap);
            if (memDc != nint.Zero)
                DeleteDC(memDc);
            ReleaseDC(nint.Zero, screenDc);
        }
    }

    private static GraphicsPath CreateRoundedRectPath(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2f, Math.Min(rect.Width, rect.Height));
        if (d <= 0.5f)
        {
            path.AddRectangle(rect);
            return path;
        }

        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    private static string ResolveMonospaceFamily()
    {
        try
        {
            var families = FontFamily.Families;
            foreach (var f in families)
            {
                if (string.Equals(f.Name, "Cascadia Mono", StringComparison.OrdinalIgnoreCase))
                    return f.Name;
            }
            foreach (var f in families)
            {
                if (string.Equals(f.Name, "Consolas", StringComparison.OrdinalIgnoreCase))
                    return f.Name;
            }
        }
        catch { }

        return FontFamily.GenericMonospace.Name;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _cachedFont?.Dispose();
            _cachedFont = null;
            _stringFormat.Dispose();
        }
        base.Dispose(disposing);
    }

    // ── Win32 Layered Window P/Invoke ────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE
    {
        public int CX;
        public int CY;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateLayeredWindow(
        nint hwnd,
        nint hdcDst,
        ref POINT pptDst,
        ref SIZE psize,
        nint hdcSrc,
        ref POINT pptSrc,
        int crKey,
        ref BLENDFUNCTION pblend,
        int dwFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        nint hWnd,
        nint hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetDC(nint hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint hWnd, nint hDC);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint CreateCompatibleDC(nint hDC);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(nint hdc);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint SelectObject(nint hDC, nint hObject);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(nint hObject);
}
