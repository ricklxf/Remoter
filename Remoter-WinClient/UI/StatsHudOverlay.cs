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

    private static readonly Color BackgroundColor = Color.FromArgb(89, 0, 0, 0);         // 0.35 alpha pure black (no border)
    private static readonly Color TextColor       = Color.FromArgb(224, 255, 255, 255); // ~0.88 alpha uniform white

    private static readonly string PreferredFontFamily = ResolveMonospaceFamily();

    private readonly Form _ownerForm;
    private readonly StringFormat _stringFormat;
    private readonly List<HudSegment[]> _lines = new(8);
    private readonly DateTime _sessionStartUtc = DateTime.UtcNow;

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
        double bitrateKbps,
        int rttMs,
        double frameMs = 0,
        string? transport = null,
        bool isRelay = false,
        double packetLossPct = 0.0,
        int width = 0,
        int height = 0)
    {
        if (IsDisposed) return;

        TimeSpan elapsed = DateTime.UtcNow - _sessionStartUtc;
        if (elapsed < TimeSpan.Zero) elapsed = TimeSpan.Zero;
        string durationLine = string.Format(
            CultureInfo.InvariantCulture,
            "{0:D2}:{1:D2}:{2:D2}",
            (int)elapsed.TotalHours,
            elapsed.Minutes,
            elapsed.Seconds);

        string proto = string.IsNullOrWhiteSpace(transport) ? "TCP" : transport.Trim().ToUpperInvariant();
        string mode = isRelay ? "relay" : "direct";
        string transportLine = $"{proto} {mode}";

        string fpsLine = $"{(int)Math.Round(fps)} fps";
        string bitrateLine = bitrateKbps < 1000.0
            ? string.Format(CultureInfo.InvariantCulture, "{0:F1} Kbps", Math.Max(0.0, bitrateKbps))
            : string.Format(CultureInfo.InvariantCulture, "{0:F1} Mbps", bitrateKbps / 1000.0);
        string rttLine = rttMs >= 0 ? $"{rttMs} ms" : "-- ms";
        string frmLine = $"{Math.Max(0, (int)Math.Round(frameMs))} ms frm.";
        string lossLine = string.Format(CultureInfo.InvariantCulture, "{0:F1}% loss", Math.Max(0.0, packetLossPct));
        string resLine = FormatResolutionTier(width, height);

        _lines.Clear();
        _lines.Add(new[] { new HudSegment(durationLine, TextColor) });
        _lines.Add(new[] { new HudSegment(transportLine, TextColor) });
        _lines.Add(new[] { new HudSegment(fpsLine, TextColor) });
        _lines.Add(new[] { new HudSegment(bitrateLine, TextColor) });
        _lines.Add(new[] { new HudSegment(rttLine, TextColor) });
        _lines.Add(new[] { new HudSegment(frmLine, TextColor) });
        _lines.Add(new[] { new HudSegment(lossLine, TextColor) });
        _lines.Add(new[] { new HudSegment(resLine, TextColor) });

        if (_hudEnabled)
        {
            RenderAndApply();
        }
    }

    private static string FormatResolutionTier(int width, int height)
    {
        if (width <= 0 || height <= 0) return "--";
        int longEdge = Math.Max(width, height);
        int shortEdge = Math.Min(width, height);
        if (longEdge >= 3840 || shortEdge >= 2160) return "4K";
        if (longEdge >= 2560 || shortEdge >= 1440) return "2K";
        if (shortEdge >= 1080) return "1080P";
        if (shortEdge >= 720) return "720P";
        return $"{shortEdge}P";
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
        _lines.Add(new[] { new HudSegment("00:00:00", TextColor) });
        _lines.Add(new[] { new HudSegment("TCP direct", TextColor) });
        _lines.Add(new[] { new HudSegment("-- fps", TextColor) });
        _lines.Add(new[] { new HudSegment("0.0 Kbps", TextColor) });
        _lines.Add(new[] { new HudSegment("-- ms", TextColor) });
        _lines.Add(new[] { new HudSegment("0 ms frm.", TextColor) });
        _lines.Add(new[] { new HudSegment("0.0% loss", TextColor) });
        _lines.Add(new[] { new HudSegment("--", TextColor) });
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
        _cachedFont = new Font(PreferredFontFamily, fontPx, FontStyle.Regular, GraphicsUnit.Pixel);
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
        int padX = (int)Math.Round(10 * scale);
        int padY = (int)Math.Round(6 * scale);
        int minWidth = (int)Math.Round(108 * scale);
        float radius = 6.0f * scale;
        float lineGap = 2.5f * scale;

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
