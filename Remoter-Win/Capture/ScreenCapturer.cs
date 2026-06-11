using System.Drawing;
using System.Drawing.Imaging;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

// Suppress the MapFlags ambiguity — we always mean D3D11 here
using D3D11MapFlags = Vortice.Direct3D11.MapFlags;

namespace RemoterWin;

// DXGI Desktop Duplication — GPU-side capture, CPU staging texture, GDI+ JPEG encode.
// Handles ACCESS_LOST (screen lock, RDP reconnect) by reinitialising the duplication.
sealed class ScreenCapturer : IDisposable
{
    private ID3D11Device?          _device;
    private ID3D11DeviceContext?   _context;
    private IDXGIOutputDuplication? _dup;
    private ID3D11Texture2D?       _staging;

    public int Width  { get; private set; }
    public int Height { get; private set; }

    // Cached JPEG encoder/params for performance (avoid per-frame lookup)
    private readonly ImageCodecInfo    _jpegCodec;
    private readonly EncoderParameters _jpegParams;

    private const int DXGI_ERROR_WAIT_TIMEOUT = unchecked((int)0x887A0027);
    private const int DXGI_ERROR_ACCESS_LOST  = unchecked((int)0x887A0026);

    public ScreenCapturer(int jpegQuality = 65)
    {
        _jpegCodec  = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        _jpegParams = new EncoderParameters(1);
        _jpegParams.Param[0] = new EncoderParameter(Encoder.Quality, (long)jpegQuality);
    }

    public void Initialize()
    {
        // 3.5.0: context parameter removed from D3D11CreateDevice; use ImmediateContext instead
        D3D11.D3D11CreateDevice(
            null,
            DriverType.Hardware,
            DeviceCreationFlags.None,
            [FeatureLevel.Level_11_0],
            out _device!
        ).CheckError();
        _context = _device.ImmediateContext;

        using var dxgiDev = _device.QueryInterface<IDXGIDevice1>();
        using var adapter = dxgiDev.GetParent<IDXGIAdapter1>();

        // 3.5.0: EnumOutputs now uses out-parameter; returns Result, not IDXGIOutput
        adapter.EnumOutputs(0, out IDXGIOutput output).CheckError();
        using (output)
        {
            var desc = output.Description;
            Width  = desc.DesktopCoordinates.Right  - desc.DesktopCoordinates.Left;
            Height = desc.DesktopCoordinates.Bottom - desc.DesktopCoordinates.Top;

            using var output1 = output.QueryInterface<IDXGIOutput1>();
            _dup = output1.DuplicateOutput(_device);
        }

        // Use convenience overload to avoid Texture2DDescription struct field name changes in 3.5.0
        _staging = _device.CreateTexture2D(
            Format.B8G8R8A8_UNorm, Width, Height,
            usage:          ResourceUsage.Staging,
            bindFlags:      BindFlags.None,
            cpuAccessFlags: CpuAccessFlags.Read
        );

        AppLog.Write($"[Capturer] {Width}x{Height} DXGI Desktop Duplication ready");
    }

    // Returns JPEG bytes, or null if no new frame was available within timeoutMs.
    // Caller drives the capture rate by calling this in a loop.
    public byte[]? CaptureJpeg(int timeoutMs = 33)
    {
        if (_dup == null || _staging == null || _context == null) return null;

        var hr = _dup.AcquireNextFrame(timeoutMs, out _, out var resource);
        if (hr.Code == DXGI_ERROR_WAIT_TIMEOUT) return null;

        if (hr.Code == DXGI_ERROR_ACCESS_LOST)
        {
            TryReinitDuplication();
            return null;
        }
        hr.CheckError();

        try
        {
            using var frameTex = resource.QueryInterface<ID3D11Texture2D>();
            _context.CopyResource(_staging, frameTex);
        }
        finally
        {
            resource.Dispose();
            _dup.ReleaseFrame();
        }

        // 3.5.0: qualify MapFlags to avoid ambiguity with Vortice.DXGI.MapFlags
        var mapped = _context.Map(_staging, 0, MapMode.Read, D3D11MapFlags.None);
        try
        {
            return EncodeJpeg(mapped.DataPointer, mapped.RowPitch, Width, Height);
        }
        finally { _context.Unmap(_staging, 0); }
    }

    // Zero-copy: Bitmap wraps the mapped staging texture pointer directly.
    private byte[] EncodeJpeg(nint dataPtr, int rowPitch, int width, int height)
    {
        using var bmp = new Bitmap(width, height, rowPitch, PixelFormat.Format32bppArgb, dataPtr);
        using var ms  = new MemoryStream(width * height / 3);
        bmp.Save(ms, _jpegCodec, _jpegParams);
        return ms.ToArray();
    }

    private void TryReinitDuplication()
    {
        try
        {
            _dup?.Dispose();
            _dup = null;
            _staging?.Dispose();
            _staging = null;
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
                usage:          ResourceUsage.Staging,
                bindFlags:      BindFlags.None,
                cpuAccessFlags: CpuAccessFlags.Read
            );
            AppLog.Write("[Capturer] DXGI duplication reinitialised");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Capturer] Reinit failed: {ex.Message}");
            Thread.Sleep(500);
        }
    }

    public void Dispose()
    {
        _dup?.Dispose();
        _staging?.Dispose();
        _context?.Dispose();
        _device?.Dispose();
        _jpegParams.Dispose();
    }
}
