using System.Drawing;
using System.Drawing.Imaging;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

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
        D3D11.D3D11CreateDevice(
            adapter:       null,
            driverType:    DriverType.Hardware,
            flags:         DeviceCreationFlags.None,
            featureLevels: [FeatureLevel.Level_11_0],
            device:        out _device!,
            context:       out _context!
        ).CheckError();

        using var dxgiDev  = _device.QueryInterface<IDXGIDevice1>();
        using var adapter  = dxgiDev.GetParent<IDXGIAdapter1>();
        using var output   = adapter.EnumOutputs(0);

        var desc = output.Description;
        Width  = desc.DesktopCoordinates.Right  - desc.DesktopCoordinates.Left;
        Height = desc.DesktopCoordinates.Bottom - desc.DesktopCoordinates.Top;

        using var output1 = output.QueryInterface<IDXGIOutput1>();
        _dup = output1.DuplicateOutput(_device);

        _staging = _device.CreateTexture2D(new Texture2DDescription
        {
            Width              = Width,
            Height             = Height,
            MipLevels          = 1,
            ArraySize          = 1,
            Format             = Format.B8G8R8A8_UNorm,
            SampleDescription  = new SampleDescription(1, 0),
            Usage              = ResourceUsage.Staging,
            BindFlags          = BindFlags.None,
            CpuAccessFlags     = CpuAccessFlags.Read,
            MiscFlags          = ResourceOptionFlags.None,
        });

        Console.WriteLine($"[Capturer] {Width}x{Height} DXGI Desktop Duplication ready");
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
            // e.g. screen locked, fullscreen app, RDP reconnect
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

        var mapped = _context.Map(_staging, 0, MapMode.Read, MapFlags.None);
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
            using var output  = adapter.EnumOutputs(0);
            using var out1    = output.QueryInterface<IDXGIOutput1>();
            _dup = out1.DuplicateOutput(_device);
            _staging = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = Width, Height = Height, MipLevels = 1, ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging, BindFlags = BindFlags.None,
                CpuAccessFlags = CpuAccessFlags.Read, MiscFlags = ResourceOptionFlags.None,
            });
            Console.WriteLine("[Capturer] DXGI duplication reinitialised");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Capturer] Reinit failed: {ex.Message}");
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
