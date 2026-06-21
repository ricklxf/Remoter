using System.Linq;
using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace RemoterWin;

// Hardware H.264 encoder via Media Foundation, driven directly through
// IMFTransform (not IMFSinkWriter — the sink writer targets file/container
// muxing and buffers for that; for live low-latency streaming we want the
// encoder MFT's raw input→output cadence with no extra buffering).
//
// MFTEnumEx picks whatever hardware MFT the driver exposes (NVENC/QuickSync/
// AMD VCE) automatically; if none is found we fall back to the software H.264
// MFT that ships with Windows itself, so this never hard-fails to "no encoder".
//
// Input: BGRA32 frames (same format ScreenCapturer already produces from the
// DXGI staging texture). The encoder wants NV12, so each frame is converted
// CPU-side — still far cheaper than the JPEG encode it replaces.
//
// Vortice.MediaFoundation doesn't expose a typed MediaTypeAttributeKeys
// wrapper (unlike SharpDX.MediaFoundation, which this file was originally
// modeled after) — media-type attributes are addressed by their well-known
// native GUID directly via IMFAttributes.Set/Get, same as every other
// Vortice.MediaFoundation consumer does.
sealed class H264Encoder : IDisposable
{
    private IMFTransform?   _transform;
    private int             _width, _height;
    private long            _frameDuration100ns; // 1 / fps in 100ns units
    private bool            _streaming;
    private byte[]          _nv12Buf = [];
    private readonly object _lock = new();

    public bool IsHardware { get; private set; }

    private static readonly Guid MftCategoryVideoEncoder = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
    private static readonly Guid MfMediaTypeVideo         = new("73646976-0000-0010-8000-00aa00389b71");

    // MF_MT_* attribute GUIDs (mfapi.h) — see comment above re: no typed wrapper.
    private static readonly Guid MF_MT_MAJOR_TYPE     = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid MF_MT_SUBTYPE        = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid MF_MT_AVG_BITRATE    = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid MF_MT_FRAME_SIZE     = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid MF_MT_FRAME_RATE     = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid MF_MT_INTERLACE_MODE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private const uint MFVideoInterlace_Progressive = 2;

    // MFT_ENUM_FLAG_* (mfapi.h)
    private const uint MFT_ENUM_FLAG_SYNCMFT      = 0x00000001;
    private const uint MFT_ENUM_FLAG_HARDWARE     = 0x00000004;
    private const uint MFT_ENUM_FLAG_SORTANDFILTER = 0x00000040;

    // 调用方需在进程启动时调一次 MediaFactory.MFStartup（main 入口已调用）。
    public void Initialize(int width, int height, int fps, int bitrateBps)
    {
        _width  = width;
        _height = height;
        _frameDuration100ns = 10_000_000L / Math.Max(fps, 1);
        _nv12Buf = new byte[width * height * 3 / 2];

        if (!TryCreateTransform(width, height, fps, bitrateBps, hardware: true))
        {
            AppLog.Write("[H264Encoder] no hardware MFT found, falling back to software H.264 encoder");
            if (!TryCreateTransform(width, height, fps, bitrateBps, hardware: false))
                throw new InvalidOperationException("No H.264 encoder MFT available (hardware or software)");
        }

        _transform!.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        _transform!.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
        _streaming = true;

        AppLog.Write($"[H264Encoder] ready {width}x{height}@{fps}fps bitrate={bitrateBps}bps hw={IsHardware}");
    }

    private bool TryCreateTransform(int width, int height, int fps, int bitrateBps, bool hardware)
    {
        try
        {
            uint flags = (hardware ? MFT_ENUM_FLAG_HARDWARE : MFT_ENUM_FLAG_SYNCMFT) | MFT_ENUM_FLAG_SORTANDFILTER;

            using var activates = MediaFactory.MFTEnumEx(
                MftCategoryVideoEncoder, flags,
                inputType:  null,
                outputType: new RegisterTypeInfo { GuidMajorType = MfMediaTypeVideo, GuidSubtype = VideoFormatGuids.H264 });

            var activate = activates.FirstOrDefault();
            int count = activates.Count();

            if (activate == null)
            {
                AppLog.Write($"[H264Encoder] MFTEnumEx found 0 candidates (hardware={hardware})");
                return false;
            }

            // activates[0] is MFTEnumEx's own quality-sorted pick (SortAndFilter).
            _transform = activate.ActivateObject<IMFTransform>();
            IsHardware = hardware;
            AppLog.Write($"[H264Encoder] picked MFT #0/{count} candidates, hardware={hardware}");

            ConfigureTypes(width, height, fps, bitrateBps);
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] TryCreateTransform(hardware={hardware}) failed: {ex.Message}");
            return false;
        }
    }

    private void ConfigureTypes(int width, int height, int fps, int bitrateBps)
    {
        // Encoder MFTs need the output (target) type set before the input type —
        // the transform uses it to decide which input formats it'll accept.
        // SetOutputType/SetInputType throw on failure (no Result return) — unlike
        // ProcessOutput below, which does return a checkable Result.
        using var outputType = MediaFactory.MFCreateMediaType();
        outputType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
        outputType.Set(MF_MT_SUBTYPE, VideoFormatGuids.H264);
        outputType.Set(MF_MT_AVG_BITRATE, (uint)bitrateBps);
        outputType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
        outputType.Set(MF_MT_FRAME_RATE, PackLong(fps, 1));
        outputType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        _transform!.SetOutputType(0, outputType, 0);

        using var inputType = MediaFactory.MFCreateMediaType();
        inputType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
        inputType.Set(MF_MT_SUBTYPE, VideoFormatGuids.NV12);
        inputType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
        inputType.Set(MF_MT_FRAME_RATE, PackLong(fps, 1));
        inputType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        _transform!.SetInputType(0, inputType, 0);
    }

    private static ulong PackLong(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    // 动态调码率（ABR 用）。Vortice.MediaFoundation 没有暴露 ICodecAPI 绑定，
    // 多数硬件 MFT 也不支持不重建 transform 就改运行时码率，所以这里只记日志、
    // 不生效——硬编码路径的码率固定在 Initialize 时设置的值，自适应交给 JPEG
    // fallback 路径（ScreenCapturer.SetQuality）。
    public void SetBitrate(int bps)
    {
        AppLog.Write($"[H264Encoder] SetBitrate({bps}) ignored — hardware MFT bitrate is fixed at init time");
    }

    // bgra: tightly-packed BGRA32, width*height*4 bytes (matches the staging
    // texture ScreenCapturer maps). Returns Annex-B H.264 bytes, or null if the
    // MFT swallowed the frame without producing output yet (it buffers a little
    // for B-frame-free low-latency profiles — caller should just send the next
    // frame and not treat null as an error).
    public byte[]? Encode(ReadOnlySpan<byte> bgra, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming) return null;

        lock (_lock)
        {
            BgraToNv12(bgra, _width, _height, _nv12Buf);

            using var buffer = MediaFactory.MFCreateMemoryBuffer(_nv12Buf.Length);
            buffer.Lock(out nint dst, out _, out _);
            Marshal.Copy(_nv12Buf, 0, dst, _nv12Buf.Length);
            buffer.Unlock();
            buffer.CurrentLength = _nv12Buf.Length;

            using var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            sample.SampleTime     = ptsMs * 10_000; // ms → 100ns units
            sample.SampleDuration = _frameDuration100ns;

            // ProcessInput throws on failure (no Result return).
            _transform.ProcessInput(0, sample, 0);

            return DrainOutput(out keyframe);
        }
    }

    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE   = unchecked((int)0xC00D6D61);
    private const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x00000100;
    private static readonly Guid MFSampleExtension_CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");

    private byte[]? DrainOutput(out bool keyframe)
    {
        keyframe = false;
        var streamInfo    = _transform!.GetOutputStreamInfo(0);
        bool mftAllocates = (streamInfo.Flags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

        IMFSample? outSample = null;
        if (!mftAllocates)
        {
            int bufSize = streamInfo.Size > 0 ? streamInfo.Size : _width * _height;
            using var outBuffer = MediaFactory.MFCreateMemoryBuffer(bufSize);
            outSample = MediaFactory.MFCreateSample();
            outSample.AddBuffer(outBuffer);
        }

        var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outSample, Status = 0, Events = null };
        var hr = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);

        if (hr.Code == MF_E_TRANSFORM_NEED_MORE_INPUT) { outSample?.Dispose(); return null; } // normal — no frame ready yet
        if (hr.Code == MF_E_TRANSFORM_STREAM_CHANGE)
        {
            AppLog.Write("[H264Encoder] MF_E_TRANSFORM_STREAM_CHANGE — output type needs renegotiation (not yet handled, dropping frame)");
            outSample?.Dispose();
            return null;
        }
        if (hr.Failure)
        {
            AppLog.Write($"[H264Encoder] ProcessOutput failed: 0x{hr.Code:X8}");
            outSample?.Dispose();
            return null;
        }

        var producedSample = dataBuffer.Sample;
        if (producedSample == null) return null;

        try
        {
            keyframe = producedSample.GetUInt32(MFSampleExtension_CleanPoint) != 0;
        }
        catch (Exception ex)
        {
            // Keyframe detection failing isn't fatal — the H.264 bitstream itself
            // still carries SPS/PPS/IDR markers the decoder can use; we just lose
            // the protocol-level keyframe hint (client requests a resync less eagerly).
            AppLog.Write($"[H264Encoder] keyframe attribute read failed (non-fatal): {ex.Message}");
        }

        using var resultBuffer = producedSample.ConvertToContiguousBuffer();
        resultBuffer.Lock(out nint src, out _, out int len);
        var bytes = new byte[len];
        Marshal.Copy(src, bytes, 0, len);
        resultBuffer.Unlock();
        producedSample.Dispose();
        return bytes;
    }

    // Straightforward BT.601 BGRA→NV12. Not SIMD-optimized — revisit if CPU
    // usage shows this as a hotspot; it's still far lighter than JPEG was.
    private static void BgraToNv12(ReadOnlySpan<byte> bgra, int width, int height, byte[] nv12)
    {
        int yPlaneSize = width * height;
        int uvOffset   = yPlaneSize;

        for (int y = 0; y < height; y++)
        {
            int rowBase = y * width * 4;
            for (int x = 0; x < width; x++)
            {
                int i = rowBase + x * 4;
                byte b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                nv12[y * width + x] = (byte)Math.Clamp((16 + (66 * r + 129 * g + 25 * b + 128) / 256), 0, 255);
            }
        }

        for (int y = 0; y < height; y += 2)
        {
            int rowBase = y * width * 4;
            for (int x = 0; x < width; x += 2)
            {
                int i = rowBase + x * 4;
                byte b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                int u = 128 + (-38 * r - 74 * g + 112 * b) / 256;
                int v = 128 + (112 * r - 94 * g - 18 * b) / 256;
                int uvIndex = uvOffset + (y / 2) * width + x;
                nv12[uvIndex]     = (byte)Math.Clamp(u, 0, 255);
                nv12[uvIndex + 1] = (byte)Math.Clamp(v, 0, 255);
            }
        }
    }

    public void Dispose()
    {
        try
        {
            if (_streaming)
            {
                _transform?.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                _transform?.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero);
            }
        }
        catch (Exception ex) { AppLog.Write($"[H264Encoder] Dispose end-stream failed: {ex.Message}"); }
        _streaming = false;
        _transform?.Dispose();
        _transform = null;
    }
}
