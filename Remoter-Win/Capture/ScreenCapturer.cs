using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

using D3D11MapFlags = Vortice.Direct3D11.MapFlags;

namespace RemoterWin;

// Screen capture with automatic fallback:
//   DXGI Desktop Duplication — GPU-side, console session only
//   GDI BitBlt               — CPU-side, works in RDP sessions too
sealed class ScreenCapturer : IDisposable
{
    // ── DXGI state ─────────────────────────────────────────────────────────
    private ID3D11Device?           _device;
    private ID3D11DeviceContext?    _context;
    private IDXGIOutputDuplication? _dup;
    private ID3D11Texture2D?        _staging;

    // ── GDI state ──────────────────────────────────────────────────────────
    private bool    _useGdi;
    private Bitmap? _gdiBmp;
    private long    _lastGdiTick;

    // ── Shared ─────────────────────────────────────────────────────────────
    public int Width  { get; private set; }
    public int Height { get; private set; }

    private readonly ImageCodecInfo    _jpegCodec;
    private readonly EncoderParameters _jpegParams;

    private const int DXGI_ERROR_WAIT_TIMEOUT = unchecked((int)0x887A0027);
    private const int DXGI_ERROR_ACCESS_LOST  = unchecked((int)0x887A0026);
    private const int ERROR_INVALID_HANDLE    = unchecked((int)0x80070006);

    [DllImport("user32.dll")] static extern int GetSystemMetrics(int n);

    // Cursor overlay P/Invokes
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] static extern bool GetIconInfo(nint hIcon, out ICONINFO pi);
    [DllImport("user32.dll")] static extern bool DrawIconEx(nint hdc, int x, int y, nint hIcon, int cx, int cy, int step, nint hbr, int flags);
    [DllImport("gdi32.dll")]  static extern bool DeleteObject(nint hObj);

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO { public int cbSize, flags; public nint hCursor; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public nint hbmMask, hbmColor; }
    private const int CURSOR_SHOWING = 1;
    private const int DI_NORMAL = 3;

    public ScreenCapturer(int jpegQuality = 65)
    {
        _jpegCodec  = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        _jpegParams = new EncoderParameters(1);
        _jpegParams.Param[0] = new EncoderParameter(Encoder.Quality, (long)jpegQuality);
    }

    public void Initialize()
    {
        try
        {
            InitializeDxgi();
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Capturer] DXGI unavailable (0x{ex.HResult:X8}), using GDI fallback");
            InitializeGdi();
        }
    }

    // ── DXGI path ───────────────────────────────────────────────────────────

    private void InitializeDxgi()
    {
        D3D11.D3D11CreateDevice(
            null, DriverType.Hardware, DeviceCreationFlags.None,
            [FeatureLevel.Level_11_0], out _device!
        ).CheckError();
        _context = _device.ImmediateContext;

        using var dxgiDev = _device.QueryInterface<IDXGIDevice1>();
        using var adapter = dxgiDev.GetParent<IDXGIAdapter1>();
        adapter.EnumOutputs(0, out IDXGIOutput output).CheckError();
        using (output)
        {
            var desc = output.Description;
            Width  = desc.DesktopCoordinates.Right  - desc.DesktopCoordinates.Left;
            Height = desc.DesktopCoordinates.Bottom - desc.DesktopCoordinates.Top;
            using var output1 = output.QueryInterface<IDXGIOutput1>();
            _dup = output1.DuplicateOutput(_device);
        }
        _staging = _device.CreateTexture2D(
            Format.B8G8R8A8_UNorm, Width, Height,
            usage: ResourceUsage.Staging, bindFlags: BindFlags.None,
            cpuAccessFlags: CpuAccessFlags.Read
        );
        AppLog.Write($"[Capturer] {Width}x{Height} DXGI Desktop Duplication ready");
    }

    private byte[]? CaptureDxgi(int timeoutMs)
    {
        if (_dup == null || _staging == null || _context == null) return null;

        var hr = _dup.AcquireNextFrame(timeoutMs, out _, out var resource);
        if (hr.Code == DXGI_ERROR_WAIT_TIMEOUT) return null;
        if (hr.Code == DXGI_ERROR_ACCESS_LOST ||
            hr.Code == ERROR_INVALID_HANDLE) { TryReinitDuplication(); return null; }
        hr.CheckError();

        try
        {
            using var frameTex = resource.QueryInterface<ID3D11Texture2D>();
            _context.CopyResource(_staging, frameTex);
        }
        finally { resource.Dispose(); _dup.ReleaseFrame(); }

        var mapped = _context.Map(_staging, 0, MapMode.Read, D3D11MapFlags.None);
        try
        {
            using var bmp = new Bitmap(Width, Height, mapped.RowPitch, PixelFormat.Format32bppArgb, mapped.DataPointer);
            using var ms  = new MemoryStream(Width * Height / 3);
            bmp.Save(ms, _jpegCodec, _jpegParams);
            return ms.ToArray();
        }
        finally { _context.Unmap(_staging, 0); }
    }

    private void TryReinitDuplication()
    {
        try
        {
            _dup?.Dispose(); _dup = null;
            _staging?.Dispose(); _staging = null;
            if (_device == null) return;

            using var dxgiDev = _device.QueryInterface<IDXGIDevice1>();
            using var adapter = dxgiDev.GetParent<IDXGIAdapter1>();
            adapter.EnumOutputs(0, out IDXGIOutput output).CheckError();
            using (output)
            {
                using var out1 = output.QueryInterface<IDXGIOutput1>();
                _dup = out1.DuplicateOutput(_device);
            }
            _staging = _device.CreateTexture2D(
                Format.B8G8R8A8_UNorm, Width, Height,
                usage: ResourceUsage.Staging, bindFlags: BindFlags.None,
                cpuAccessFlags: CpuAccessFlags.Read
            );
            AppLog.Write("[Capturer] DXGI duplication reinitialised");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Capturer] DXGI reinit failed: {ex.Message}, switching to GDI");
            try { InitializeGdi(); }
            catch (Exception gex) { AppLog.Write($"[Capturer] GDI fallback failed: {gex.Message}"); }
        }
    }

    // ── GDI path ────────────────────────────────────────────────────────────

    private void InitializeGdi()
    {
        Width   = GetSystemMetrics(0); // SM_CXSCREEN
        Height  = GetSystemMetrics(1); // SM_CYSCREEN
        _gdiBmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        _useGdi = true;
        AppLog.Write($"[Capturer] {Width}x{Height} GDI BitBlt ready");
    }

    private void DrawCursorOnGraphics(Graphics g)
    {
        var ci = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref ci) || ci.flags != CURSOR_SHOWING || ci.hCursor == nint.Zero) return;

        int drawX = ci.pt.x;
        int drawY = ci.pt.y;
        if (GetIconInfo(ci.hCursor, out var ii))
        {
            drawX -= ii.xHotspot;
            drawY -= ii.yHotspot;
            if (ii.hbmMask  != nint.Zero) DeleteObject(ii.hbmMask);
            if (ii.hbmColor != nint.Zero) DeleteObject(ii.hbmColor);
        }

        var hdc = g.GetHdc();
        try { DrawIconEx(hdc, drawX, drawY, ci.hCursor, 0, 0, 0, nint.Zero, DI_NORMAL); }
        finally { g.ReleaseHdc(hdc); }
    }

    private byte[]? CaptureGdi(int targetFps = 30)
    {
        // Throttle to targetFps
        long now      = Environment.TickCount64;
        long interval = 1000 / targetFps;
        if (now - _lastGdiTick < interval) return null;
        _lastGdiTick = now;

        if (_gdiBmp == null) return null;
        try
        {
            using var g = Graphics.FromImage(_gdiBmp);
            g.CopyFromScreen(0, 0, 0, 0, new Size(Width, Height), CopyPixelOperation.SourceCopy);
            DrawCursorOnGraphics(g);
            using var ms = new MemoryStream(Width * Height / 3);
            _gdiBmp.Save(ms, _jpegCodec, _jpegParams);
            return ms.ToArray();
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Capturer] GDI frame error (0x{ex.HResult:X8}): {ex.Message}");
            return null;
        }
    }

    // ── Public API ──────────────────────────────────────────────────────────

    public byte[]? CaptureJpeg(int timeoutMs = 33) =>
        _useGdi ? CaptureGdi() : CaptureDxgi(timeoutMs);

    public void Dispose()
    {
        _dup?.Dispose();
        _staging?.Dispose();
        _context?.Dispose();
        _device?.Dispose();
        _gdiBmp?.Dispose();
        _jpegParams.Dispose();
    }
}
