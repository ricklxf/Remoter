using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using VorticeD3D11 = Vortice.Direct3D11;

namespace RemoterWinClient;

/// <summary>
/// High-performance FFmpeg 7.x video decoder with D3D11VA GPU zero-copy hardware acceleration
/// for both H.264 and H.265 (HEVC), bypassing Windows Media Foundation MFT driver quirks and
/// Microsoft Store paid HEVC extension requirements.
///
/// Shares D3D11Renderer's ID3D11Device via AVD3D11VADeviceContext so decoded NV12/P010 GPU
/// texture array slices are copied directly on the GPU via CopySubresourceRegion (0 CPU copy).
/// Gracefully falls back to FFmpeg multi-threaded slice SW decode if D3D11VA init fails.
/// </summary>
public sealed unsafe class FfmpegVideoDecoder : IDisposable
{
    private static readonly object s_probeLock = new();
    private static bool s_probed;
    private static string? s_ffmpegRootPath;

    private readonly object _lock = new();
    private AVCodecContext* _codecCtx;
    private AVFrame* _frame;
    private AVPacket* _packet;
    private AVCodecContext_get_format? _getFormatCallback; // pinned delegate for unmanaged callback lifetime

    private byte[]? _cpuNv12Buf;
    private VideoCodecType _codec = VideoCodecType.H264;
    private int _width;
    private int _height;
    private bool _isHardware;
    private bool _isGpuZeroCopy;
    private bool _disposed;
    private bool _awaitingKeyframe = true;
    private DecodedPixelFormat _outputFormat = DecodedPixelFormat.Nv12;

    private long _decodedFrames;
    private long _droppedFrames;
    private double _lastDecodeMs;
    private string _lastError = "";

    public bool IsHardware => _isHardware;
    public bool IsGpuZeroCopy => _isGpuZeroCopy;
    public DecodedPixelFormat OutputFormat => _outputFormat;
    public long DecodedFrames => _decodedFrames;
    public long DroppedFrames => _droppedFrames;
    public double LastDecodeMs => _lastDecodeMs;
    public string LastError => _lastError;

    /// <summary>
    /// True GPU zero-copy callback: (ID3D11Texture2D, arraySlice, width, height, pixelFormat).
    /// Texture is valid for the duration of the callback only.
    /// </summary>
    public Action<VorticeD3D11.ID3D11Texture2D, int, int, int, DecodedPixelFormat>? OnGpuFrame;

    /// <summary>
    /// CPU NV12 fallback callback: (nv12Ptr, stride, width, height).
    /// </summary>
    public Action<nint, int, int, int>? OnCpuNv12Frame;

    /// <summary>
    /// Raised when decode errors require a fresh IDR keyframe from the host.
    /// </summary>
    public Action? OnKeyframeNeeded;

    /// <summary>
    /// Returns true if FFmpeg 7.x shared libraries (avcodec-61.dll + avutil-59.dll) are present
    /// in the application directory, ./ffmpeg/, or %LocalAppData%/RemoterWinClient/ffmpeg/.
    /// </summary>
    public static bool IsAvailable => FindFfmpegRootPath() != null;

    public static string? FindFfmpegRootPath()
    {
        lock (s_probeLock)
        {
            if (s_probed) return s_ffmpegRootPath;
            s_probed = true;

            string baseDir = AppContext.BaseDirectory;
            string localAppFfmpeg = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "RemoterWinClient",
                "ffmpeg");

            string[] candidates =
            [
                Path.Combine(baseDir, "ffmpeg"),
                baseDir,
                localAppFfmpeg,
            ];

            foreach (string dir in candidates)
            {
                if (Directory.Exists(dir) &&
                    File.Exists(Path.Combine(dir, "avcodec-61.dll")) &&
                    File.Exists(Path.Combine(dir, "avutil-59.dll")))
                {
                    s_ffmpegRootPath = dir;
                    ffmpeg.RootPath = dir;
                    return s_ffmpegRootPath;
                }
            }

            return null;
        }
    }

    public void Initialize(VideoCodecType codec, int width, int height, VorticeD3D11.ID3D11Device? d3d11Device)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ReleaseInternal();

            string? root = FindFfmpegRootPath();
            if (root == null)
            {
                throw new DllNotFoundException("FFmpeg 7.x DLLs (avcodec-61.dll, avutil-59.dll) not found.");
            }

            _codec = codec;
            _width = width;
            _height = height;
            _awaitingKeyframe = true;
            _isHardware = false;
            _isGpuZeroCopy = false;
            _outputFormat = DecodedPixelFormat.Nv12;
            _lastError = "";

            AVCodecID codecId = codec == VideoCodecType.H265
                ? AVCodecID.AV_CODEC_ID_HEVC
                : AVCodecID.AV_CODEC_ID_H264;

            AVCodec* avCodec = ffmpeg.avcodec_find_decoder(codecId);
            if (avCodec == null)
            {
                throw new InvalidOperationException($"FFmpeg decoder not found for {codec}");
            }

            AVCodecContext* ctx = ffmpeg.avcodec_alloc_context3(avCodec);
            if (ctx == null)
            {
                throw new OutOfMemoryException("avcodec_alloc_context3 returned null");
            }

            try
            {
                ctx->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
                ctx->flags2 |= ffmpeg.AV_CODEC_FLAG2_FAST;
                ctx->width = width;
                ctx->height = height;

                bool d3d11Attached = false;
                if (d3d11Device != null && d3d11Device.NativePointer != nint.Zero)
                {
                    d3d11Attached = TryAttachD3D11Device(ctx, d3d11Device);
                }

                if (d3d11Attached)
                {
                    // Hardware D3D11VA decode: 1 thread = 0-frame pipeline delay
                    ctx->thread_count = 1;
                    _getFormatCallback = SelectD3D11PixelFormat;
                    ctx->get_format = _getFormatCallback;
                    _isHardware = true;
                    _isGpuZeroCopy = true;
                }
                else
                {
                    // Software fallback: slice threading preserves 0-frame latency
                    ctx->thread_count = Math.Clamp(Environment.ProcessorCount / 2, 2, 6);
                    ctx->thread_type = ffmpeg.FF_THREAD_SLICE;
                    _isHardware = false;
                    _isGpuZeroCopy = false;
                }

                int openRet = ffmpeg.avcodec_open2(ctx, avCodec, null);
                if (openRet < 0)
                {
                    throw new InvalidOperationException($"avcodec_open2({codec}) failed: {GetErrorString(openRet)}");
                }

                _frame = ffmpeg.av_frame_alloc();
                _packet = ffmpeg.av_packet_alloc();
                if (_frame == null || _packet == null)
                {
                    throw new OutOfMemoryException("Failed to allocate AVFrame/AVPacket");
                }

                _codecCtx = ctx;
            }
            catch
            {
                AVCodecContext* toFree = ctx;
                ffmpeg.avcodec_free_context(&toFree);
                ReleaseInternal();
                throw;
            }
        }
    }

    private static bool TryAttachD3D11Device(AVCodecContext* ctx, VorticeD3D11.ID3D11Device d3d11Device)
    {
        AVBufferRef* hwDeviceRef = ffmpeg.av_hwdevice_ctx_alloc(AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA);
        if (hwDeviceRef == null) return false;

        try
        {
            AVHWDeviceContext* hwDevCtx = (AVHWDeviceContext*)hwDeviceRef->data;
            AVD3D11VADeviceContext* d3d11Ctx = (AVD3D11VADeviceContext*)hwDevCtx->hwctx;

            // AddRef so FFmpeg's av_buffer_unref owns an independent COM reference
            Marshal.AddRef(d3d11Device.NativePointer);
            d3d11Ctx->device = (FFmpeg.AutoGen.ID3D11Device*)d3d11Device.NativePointer;

            int ret = ffmpeg.av_hwdevice_ctx_init(hwDeviceRef);
            if (ret < 0)
            {
                ffmpeg.av_buffer_unref(&hwDeviceRef);
                return false;
            }

            ctx->hw_device_ctx = ffmpeg.av_buffer_ref(hwDeviceRef);
            ffmpeg.av_buffer_unref(&hwDeviceRef);
            return ctx->hw_device_ctx != null;
        }
        catch
        {
            if (hwDeviceRef != null)
            {
                ffmpeg.av_buffer_unref(&hwDeviceRef);
            }
            return false;
        }
    }

    private static AVPixelFormat SelectD3D11PixelFormat(AVCodecContext* ctx, AVPixelFormat* pixFmts)
    {
        if (pixFmts == null) return AVPixelFormat.AV_PIX_FMT_NONE;
        for (AVPixelFormat* p = pixFmts; *p != AVPixelFormat.AV_PIX_FMT_NONE; p++)
        {
            if (*p == AVPixelFormat.AV_PIX_FMT_D3D11)
            {
                return AVPixelFormat.AV_PIX_FMT_D3D11;
            }
        }
        return *pixFmts;
    }

    public bool Decode(byte[] annexBData, bool isKeyframe, long ptsUs)
    {
        if (annexBData == null || annexBData.Length == 0) return false;

        lock (_lock)
        {
            if (_disposed || _codecCtx == null || _frame == null || _packet == null)
            {
                return false;
            }

            if (_awaitingKeyframe)
            {
                if (!isKeyframe)
                {
                    _droppedFrames++;
                    return false;
                }
                _awaitingKeyframe = false;
            }

            long t0 = Stopwatch.GetTimestamp();
            bool emitted = false;

            fixed (byte* dataPtr = annexBData)
            {
                _packet->data = dataPtr;
                _packet->size = annexBData.Length;
                _packet->pts = ptsUs;
                _packet->dts = ptsUs;
                _packet->flags = isKeyframe ? ffmpeg.AV_PKT_FLAG_KEY : 0;

                int sendRet = ffmpeg.avcodec_send_packet(_codecCtx, _packet);
                // Clear borrowed pointer immediately so av_packet_unref never frees managed memory
                _packet->data = null;
                _packet->size = 0;

                if (sendRet < 0)
                {
                    _lastError = $"send_packet: {GetErrorString(sendRet)}";
                    _droppedFrames++;
                    _awaitingKeyframe = true;
                    OnKeyframeNeeded?.Invoke();
                    return false;
                }
            }

            while (true)
            {
                int recvRet = ffmpeg.avcodec_receive_frame(_codecCtx, _frame);
                if (recvRet == ffmpeg.AVERROR(ffmpeg.EAGAIN) || recvRet == ffmpeg.AVERROR_EOF)
                {
                    break;
                }
                if (recvRet < 0)
                {
                    _lastError = $"receive_frame: {GetErrorString(recvRet)}";
                    _droppedFrames++;
                    _awaitingKeyframe = true;
                    OnKeyframeNeeded?.Invoke();
                    break;
                }

                try
                {
                    DeliverFrame(_frame);
                    _decodedFrames++;
                    emitted = true;
                }
                finally
                {
                    ffmpeg.av_frame_unref(_frame);
                }
            }

            if (emitted)
            {
                _lastDecodeMs = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
            }

            return emitted;
        }
    }

    private void DeliverFrame(AVFrame* frame)
    {
        int w = frame->width;
        int h = frame->height;
        if (w <= 0 || h <= 0) return;

        var pixFmt = (AVPixelFormat)frame->format;
        if (pixFmt == AVPixelFormat.AV_PIX_FMT_D3D11)
        {
            nint texPtr = (nint)frame->data[0];
            int subIdx = (int)(nint)frame->data[1];
            if (texPtr == nint.Zero) return;

            DecodedPixelFormat fmt = DecodedPixelFormat.Nv12;
            if (frame->hw_frames_ctx != null)
            {
                AVHWFramesContext* framesCtx = (AVHWFramesContext*)frame->hw_frames_ctx->data;
                if (framesCtx != null && framesCtx->sw_format == AVPixelFormat.AV_PIX_FMT_P010LE)
                {
                    fmt = DecodedPixelFormat.P010;
                }
            }
            _outputFormat = fmt;
            _isHardware = true;
            _isGpuZeroCopy = true;

            // AddRef so Vortice's Dispose balances its Release without touching FFmpeg's ref
            Marshal.AddRef(texPtr);
            using var tex = new VorticeD3D11.ID3D11Texture2D(texPtr);
            OnGpuFrame?.Invoke(tex, subIdx, w, h, fmt);
            return;
        }

        // Software decode fallback (NV12 or YUV420P) -> pack contiguous NV12 buffer
        _isGpuZeroCopy = false;
        _outputFormat = DecodedPixelFormat.Nv12;

        int nv12Size = w * h * 3 / 2;
        if (_cpuNv12Buf == null || _cpuNv12Buf.Length < nv12Size)
        {
            _cpuNv12Buf = new byte[nv12Size];
        }

        fixed (byte* dstBase = _cpuNv12Buf)
        {
            byte* ySrc = frame->data[0];
            int yStride = frame->linesize[0];
            for (int row = 0; row < h; row++)
            {
                Buffer.MemoryCopy(ySrc + row * yStride, dstBase + row * w, w, w);
            }

            byte* uvDst = dstBase + (w * h);
            int chromaH = h / 2;
            int chromaW = w / 2;

            if (pixFmt == AVPixelFormat.AV_PIX_FMT_NV12)
            {
                byte* uvSrc = frame->data[1];
                int uvStride = frame->linesize[1];
                for (int row = 0; row < chromaH; row++)
                {
                    Buffer.MemoryCopy(uvSrc + row * uvStride, uvDst + row * w, w, w);
                }
            }
            else if (pixFmt == AVPixelFormat.AV_PIX_FMT_YUV420P || pixFmt == AVPixelFormat.AV_PIX_FMT_YUVJ420P)
            {
                byte* uSrc = frame->data[1];
                byte* vSrc = frame->data[2];
                int uStride = frame->linesize[1];
                int vStride = frame->linesize[2];

                for (int row = 0; row < chromaH; row++)
                {
                    byte* uRow = uSrc + row * uStride;
                    byte* vRow = vSrc + row * vStride;
                    byte* dstRow = uvDst + row * w;
                    for (int col = 0; col < chromaW; col++)
                    {
                        dstRow[col * 2] = uRow[col];
                        dstRow[col * 2 + 1] = vRow[col];
                    }
                }
            }
            else
            {
                return;
            }

            OnCpuNv12Frame?.Invoke((nint)dstBase, w, w, h);
        }
    }

    public void Flush()
    {
        lock (_lock)
        {
            if (_codecCtx != null)
            {
                ffmpeg.avcodec_flush_buffers(_codecCtx);
            }
            _awaitingKeyframe = true;
        }
    }

    private void ReleaseInternal()
    {
        if (_frame != null)
        {
            AVFrame* f = _frame;
            _frame = null;
            ffmpeg.av_frame_free(&f);
        }
        if (_packet != null)
        {
            AVPacket* p = _packet;
            _packet = null;
            ffmpeg.av_packet_free(&p);
        }
        if (_codecCtx != null)
        {
            AVCodecContext* c = _codecCtx;
            _codecCtx = null;
            ffmpeg.avcodec_free_context(&c);
        }
        _getFormatCallback = null;
    }

    private static string GetErrorString(int errnum)
    {
        byte* buf = stackalloc byte[128];
        ffmpeg.av_strerror(errnum, buf, 128);
        return Marshal.PtrToStringUTF8((nint)buf) ?? $"err={errnum}";
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            ReleaseInternal();
            _cpuNv12Buf = null;
        }
    }
}
