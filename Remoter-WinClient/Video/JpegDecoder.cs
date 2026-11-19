using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace RemoterWinClient;

/// <summary>
/// Fast GDI+ fallback decoder for JPEG video frames into BGRA32 buffers
/// compatible with D3D11Renderer.RenderBgra().
/// </summary>
public sealed class JpegDecoder : IDisposable
{
    private readonly object _lock = new();
    private byte[] _bgraPool = [];
    private bool _disposed;

    /// <summary>
    /// Decodes a JPEG byte span into a reusable tightly-packed BGRA32 buffer.
    /// </summary>
    public unsafe bool DecodeToBgra(
        ReadOnlySpan<byte> jpegData,
        out byte[] bgraBuffer,
        out int width,
        out int height,
        out int stride)
    {
        bgraBuffer = [];
        width = 0;
        height = 0;
        stride = 0;

        if (jpegData.IsEmpty) return false;

        lock (_lock)
        {
            if (_disposed) return false;

            try
            {
                using var ms = new MemoryStream(jpegData.ToArray(), writable: false);
                using var bmp = new Bitmap(ms);

                width = bmp.Width;
                height = bmp.Height;
                if (width <= 0 || height <= 0) return false;

                var rect = new Rectangle(0, 0, width, height);
                var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    int rowBytes = width * 4;
                    int totalBytes = rowBytes * height;
                    if (_bgraPool.Length < totalBytes)
                    {
                        _bgraPool = new byte[totalBytes];
                    }

                    if (data.Stride == rowBytes)
                    {
                        Marshal.Copy(data.Scan0, _bgraPool, 0, totalBytes);
                    }
                    else
                    {
                        byte* src = (byte*)data.Scan0;
                        for (int y = 0; y < height; y++)
                        {
                            Marshal.Copy((nint)(src + (long)y * data.Stride), _bgraPool, y * rowBytes, rowBytes);
                        }
                    }

                    bgraBuffer = _bgraPool;
                    stride = rowBytes;
                    return true;
                }
                finally
                {
                    bmp.UnlockBits(data);
                }
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Decodes a JPEG frame and uploads directly from BitmapData.Scan0 into D3D11Renderer
    /// without an intermediate managed byte[] copy.
    /// </summary>
    public bool DecodeAndRender(ReadOnlySpan<byte> jpegData, D3D11Renderer renderer)
    {
        if (jpegData.IsEmpty || renderer == null) return false;

        lock (_lock)
        {
            if (_disposed) return false;

            try
            {
                using var ms = new MemoryStream(jpegData.ToArray(), writable: false);
                using var bmp = new Bitmap(ms);

                int width = bmp.Width;
                int height = bmp.Height;
                if (width <= 0 || height <= 0) return false;

                var rect = new Rectangle(0, 0, width, height);
                var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    renderer.RenderBgra(data.Scan0, width, height, data.Stride);
                    return true;
                }
                finally
                {
                    bmp.UnlockBits(data);
                }
            }
            catch
            {
                return false;
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            _bgraPool = [];
        }
    }
}
